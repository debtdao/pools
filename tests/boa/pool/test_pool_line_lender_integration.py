import boa
import ape
import math
import pytest
from boa.vyper.contract import BoaError, VyperContract
from hypothesis import given, settings
from hypothesis import strategies as st
from hypothesis.stateful import RuleBasedStateMachine, run_state_machine_as_test, rule, invariant
from eth_utils import to_checksum_address
from datetime import timedelta
from ..utils.events import _find_event, _find_event_by
from ..utils.price import _to_assets, _to_shares, _calc_price
from .conftest import INTEREST_TIMESPAN_SEC, DRATE, FRATE, FEE_COEFFICIENT, MAX_PITTANCE_FEE, NULL_POSITION
from ..conftest import ZERO_ADDRESS, INIT_USER_POOL_BALANCE, INIT_POOL_BALANCE, MAX_UINT, POOL_PRICE_DECIMALS

BYTES32_STRING = 0x0000000000000000000000000000000000000000000000000000000000000000
INTEREST_RATE_COEFFICIENT = 315576000000

########################################
########################################
########################################
#####                               ####
#####       Credit Investment       ####
#####                               ####
########################################
########################################
########################################
@pytest.mark.pool
@pytest.mark.pool_owner
@pytest.mark.line_integration
def test_only_pool_owner_can_invest_in_lines(pool, mock_line, admin, me, base_asset, init_token_balances):
    # init_token_balances auto deposits so we have funds available

    # new 4626 vault to invest in
    new_pool = boa.load("contracts/DebtDAOPool.vy", admin, base_asset, "New Pool", "NEW", [0,0,0,0,0,0])
    with boa.reverts():
        pool.invest_vault(new_pool, 1, sender=me)
    pool.invest_vault(new_pool, 1, sender=admin)
    
    with boa.reverts():
        pool.add_credit(mock_line, 0, 0, 1, sender=me)
    id = pool.add_credit(mock_line, 0, 0, 1, sender=admin)
    
    with boa.reverts():
        pool.increase_credit(mock_line, id, 1, sender=me)
    with boa.reverts():
        pool.set_rates(mock_line, id, 100, 100, sender=me)
    pool.increase_credit(mock_line, id, 1, sender=admin)
    pool.set_rates(mock_line, id, 100, 100, sender=admin)


@pytest.mark.pool
@pytest.mark.line_integration
@given(amount=st.integers(min_value=1, max_value=INIT_POOL_BALANCE),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_pool_can_deposit_to_line(
    pool, mock_line, admin, me, base_asset,
     _add_credit, _get_position, init_token_balances,
     amount
):
    start_balance = init_token_balances * 2
    id = _add_credit(amount)

    assert base_asset.balances(pool) == start_balance
    assert base_asset.balances(mock_line) == amount

    position = _get_position(mock_line, id)

    assert to_checksum_address(position['lender']) == pool.address
    assert position['deposit'] == amount
    assert to_checksum_address(position['token']) == base_asset.address
    assert base_asset.balances(pool) == start_balance
    assert base_asset.balances(mock_line) == amount


@pytest.mark.pool
@pytest.mark.line_integration
@given(amount=st.integers(min_value=1, max_value=INIT_POOL_BALANCE),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_pool_can_increase_deposit_to_line(
    pool, mock_line, admin, me, base_asset,
    _deposit, _add_credit, _get_position, init_token_balances,
    amount
):
    start_balance = init_token_balances * 2
    _deposit(amount * 2, me)
    id = _add_credit(amount, new_deposit=False)
    position = _get_position(mock_line, id)

    assert to_checksum_address(position['lender']) == pool.address
    assert position['deposit'] == amount
    assert to_checksum_address(position['token']) == base_asset.address
    assert base_asset.balances(pool) == start_balance + amount
    assert base_asset.balances(mock_line) == amount

    pool.increase_credit(mock_line, id, amount, sender=admin)

    position2 = _get_position(mock_line, id)

    assert to_checksum_address(position2['lender']) == pool.address
    assert position2['deposit'] == amount * 2
    assert to_checksum_address(position2['token']) == base_asset.address
    assert base_asset.balances(pool) == start_balance
    assert base_asset.balances(mock_line) == amount * 2


@pytest.mark.pool
@pytest.mark.line_integration
@given(drate=st.integers(min_value=1, max_value=10**10),
        frate=st.integers(min_value=1, max_value=10**10),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_pool_can_change_rates_on_existing_position(
    pool, mock_line, admin, me, base_asset,
    _add_credit, _get_position, drate, frate
):
    amount = 1
    id = _add_credit(amount * 2)
    position = _get_position(mock_line, id)

    # ensure proper position for id
    assert to_checksum_address(position['lender']) == pool.address
    assert to_checksum_address(position['token']) == base_asset.address
    
    [drate, frate, _] = mock_line.rates(id)
    assert drate == 0 and frate == 0

    pool.set_rates(mock_line, id, drate, frate, sender=admin)

    [drate2, frate2, _] = mock_line.rates(id)
    assert drate2 == drate and frate2 == frate

    # can set back to 0
    pool.set_rates(mock_line, id, 0, 0, sender=admin)

    [drate2, frate2, _] = mock_line.rates(id)
    assert drate2 == 0 and frate2 == 0

########################################
########################################
########################################
#####                               ####
#####         Profit Taking         ####
#####                               ####
########################################
########################################
########################################

@pytest.mark.pool
@pytest.mark.line_integration
@given(amount=st.integers(min_value=10**18, max_value=10**25),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_collecting_interest_to_pool_increases_total_assets_and_locked_profit(
    pool, mock_line, admin, me, base_asset,
    _add_credit, _get_position, _repay,
    amount,
):
    facility_fee = 1000 # 10%
    id = _add_credit(amount, 0, facility_fee)
    p = _get_position(mock_line, id)

    assert p['deposit'] == amount

    boa.env.time_travel(seconds=INTEREST_TIMESPAN_SEC)
    mock_line.accrueInterest(id)
    
    p2 = _get_position(mock_line, id)
    expected_interest = p2['interestAccrued']
    assert pool.totalAssets() == INIT_POOL_BALANCE + amount # ensure original accounting balance
    assert p2['interestAccrued'] == expected_interest
    assert p2['interestRepaid'] == 0

    _repay(mock_line, id, 1)

    collected =  pool.collect_interest(mock_line, id)
    assert collected == 1
    assert pool.totalAssets() == INIT_POOL_BALANCE + amount + 1
    assert pool.locked_profits() == 1 # no matter the vesting_rate MUST have 100% at block of collection


    ### TODO TEST reduce_credit and impair function similarly

@pytest.mark.pool
@pytest.mark.line_integration
@given(amount=st.integers(min_value=10**18, max_value=10**25),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_stacks_collected_profits(
    pool, mock_line, admin, me, base_asset,
    _add_credit, _get_position, _repay,
    amount,
):
    facility_fee = 1000 # 10%
    id = _add_credit(amount, 0, facility_fee)
    p = _get_position(mock_line, id)

    assert p['deposit'] == amount

    boa.env.time_travel(seconds=INTEREST_TIMESPAN_SEC)
    mock_line.accrueInterest(id)
    
    p2 = _get_position(mock_line, id)
    expected_interest = p2['interestAccrued']
    assert pool.totalAssets() == INIT_POOL_BALANCE + amount # ensure original accounting balance
    assert p2['interestAccrued'] == expected_interest
    assert p2['interestRepaid'] == 0

    ## test adding profit oon top each other
    _repay(mock_line, id, expected_interest - 100)

    collected =  pool.collect_interest(mock_line, id)
    assert collected == expected_interest - 100
    assert pool.totalAssets() == INIT_POOL_BALANCE + amount + expected_interest - 100
    assert pool.locked_profits() == expected_interest - 100 # no matter the vesting_rate MUST have 100% at block of collection
    
    _repay(mock_line, id, 100)

    collected =  pool.collect_interest(mock_line, id)
    assert collected == 100
    assert pool.totalAssets() == INIT_POOL_BALANCE + amount + expected_interest
    assert pool.locked_profits() == expected_interest # no matter the vesting_rate MUST have 100% at block of collection



@pytest.mark.pool
@pytest.mark.line_integration
@given(amount=st.integers(min_value=10**18, max_value=10**25),
       withdrawn=st.integers(min_value=10**24, max_value=2*10**25),)
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_reduce_credit_cant_pull_more_funds_than_in_position(
    pool, mock_line, admin, me, base_asset,
    _add_credit, _get_position, _repay,
    amount, withdrawn,
):
    facility_fee = 1000 # 10%
    id = _add_credit(amount, 0, facility_fee)
    p = _get_position(mock_line, id)

    assert p['deposit'] == amount

    boa.env.time_travel(seconds=INTEREST_TIMESPAN_SEC)
    mock_line.accrueInterest(id)
    
    p2 = _get_position(mock_line, id)
    expected_interest = p2['interestAccrued']
    assert pool.totalAssets() == amount # ensure original accounting balance
    assert pool.total_deployed() == amount # ensure original accounting balance
    assert p2['interestAccrued'] == expected_interest
    assert p2['interestRepaid'] == 0

    _repay(mock_line, id, expected_interest)
    
    print(f"pool assets/deployed/withdrawn {pool.totalAssets()}  -- {pool.total_deployed()} -- {withdrawn}")

    if withdrawn > amount:
        with boa.reverts():
            pool.reduce_credit(mock_line, id, withdrawn, sender=admin)

@pytest.mark.pool
@pytest.mark.line_integration
@given(amount=st.integers(min_value=10**18, max_value=10**25),
       withdrawn=st.integers(min_value=10**18, max_value=10**25),)
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_reduce_credit_increases_total_assets_and_locked_profit_and_decreases_total_deployed(
    pool, mock_line, admin, me, base_asset,
    _add_credit, _get_position, _repay,
    amount, withdrawn,
):
    facility_fee = 1000 # 10%
    id = _add_credit(amount, 0, facility_fee)
    p = _get_position(mock_line, id)

    assert p['deposit'] == amount

    boa.env.time_travel(seconds=INTEREST_TIMESPAN_SEC)
    mock_line.accrueInterest(id)
    
    p2 = _get_position(mock_line, id)
    expected_interest = p2['interestAccrued']
    assert pool.totalAssets() == amount # ensure original accounting balance
    assert pool.total_deployed() == amount # ensure original accounting balance
    assert p2['interestAccrued'] == expected_interest
    assert p2['interestRepaid'] == 0

    _repay(mock_line, id, expected_interest)

    # cap interest to withdrawn
    if withdrawn < expected_interest:
        expected_interest = withdrawn

    if withdrawn > amount + expected_interest:
        with boa.reverts():
            pool.reduce_credit(mock_line, id, withdrawn, sender=admin)
    else:
        [collected_deposit, collected_interest] =  pool.reduce_credit(mock_line, id, withdrawn, sender=admin)
        
        assert collected_interest == expected_interest
        assert collected_deposit == withdrawn - expected_interest

        new_pool_assets = amount + expected_interest
        assert pool.totalAssets() == new_pool_assets
        assert pool.locked_profits() == expected_interest # no matter the vesting_rate MUST have 100% at block of collection
        assert pool.total_deployed() == amount - collected_deposit  # no matter the vesting_rate MUST have 100% at block of collection



@pytest.mark.pool
@pytest.mark.line_integration
def test_anyone_can_call_collect_interest(
    pool, mock_line, admin, me, base_asset,
    _add_credit, _get_position, _repay,
):
    amount = INIT_POOL_BALANCE
    facility_fee = 1000 # 10%
    
    id = _add_credit(amount, 0, facility_fee)
    p = _get_position(mock_line, id)
    assert p['deposit'] == amount

    # print("time before travel", boa.env.get_block)

    boa.env.time_travel(seconds=INTEREST_TIMESPAN_SEC)
    
    mock_line.accrueInterest(id)
    # without math.floow this has extra 1e19 for some reason

    p2 = _get_position(mock_line, id)
    expected_interest = p2['interestAccrued']
    assert p2['interestRepaid'] == 0
    assert p2['interestAccrued'] == expected_interest

    _repay(mock_line, id, expected_interest)
    
    p3 = _get_position(mock_line, id)
    assert p3['interestRepaid'] == expected_interest

    assert pool.locked_profits() == 0
    rando = boa.env.generate_address()
    pool.collect_interest(mock_line, id, sender=rando)
    assert pool.locked_profits() == expected_interest
    assert pool.totalAssets() == INIT_POOL_BALANCE + amount + expected_interest
    
    p4 = _get_position(mock_line, id)
    assert p4['interestRepaid'] == 0 


@pytest.mark.pool
@pytest.mark.pool_owner
@pytest.mark.line_integration
def test_only_owner_can_reduce_credit(
    pool, mock_line, admin, me, base_asset,
    _add_credit, _get_position, _repay,
):
    id = _add_credit(100, 0, 0, line=mock_line)

    with boa.reverts():
        pool.reduce_credit(mock_line, id, 10_000, sender=me)
    with boa.reverts():
        pool.reduce_credit(mock_line, id, 0, sender=me) # should still revert if no state change

    pool.reduce_credit(mock_line, id, 100, sender=admin)


@pytest.mark.pool
@pytest.mark.pool_owner
@pytest.mark.line_integration
def test_reduce_credit_with_max_uint_pulls_all_funds(
    pool, mock_line, my_line, admin, me, base_asset,
    _add_credit, _get_position, _repay,
):
    amount = INIT_POOL_BALANCE
    facility_fee = 1000 # 10%
    
    id = _add_credit(amount, 0, facility_fee)
    id2 = _add_credit(amount, 0, facility_fee, line=my_line)
    
    assert _get_position(mock_line, id)['deposit'] == amount
    assert _get_position(my_line, id2)['deposit'] == amount
    assert pool.total_deployed() == amount * 2

    # test pulling all deposit with no interest
    pool.reduce_credit(my_line, id2, MAX_UINT, sender=admin)
    assert _get_position(my_line, id2)['deposit'] == 0
    assert pool.total_deployed() == amount

    boa.env.time_travel(seconds=INTEREST_TIMESPAN_SEC)
    
    mock_line.accrueInterest(id)

    p3 = _get_position(mock_line, id)
    expected_interest = p3['interestAccrued']
    assert p3['interestRepaid'] == 0
    assert p3['interestAccrued'] == expected_interest

    _repay(mock_line, id, expected_interest)
    
    p4 = _get_position(mock_line, id)
    assert p4['interestRepaid'] == expected_interest

    assert pool.locked_profits() == 0
    pool.reduce_credit(mock_line, id, MAX_UINT, sender=admin)
    assert pool.locked_profits() == expected_interest
    assert pool.totalAssets() == (amount * 2) + expected_interest
    assert pool.total_deployed() == 0


@pytest.mark.pool
@pytest.mark.line_integration
@pytest.mark.share_price
@given(deposited=st.integers(min_value=10**18, max_value=10**25), # min_val = 1 so no off by one when adjusting values
        withdrawn=st.integers(min_value=10**18, max_value=10**25),
        timespan = st.integers(min_value=0, max_value=INTEREST_TIMESPAN_SEC)) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_reduce_credit_increases_total_assets_plus_locked_profit_and_reduces_total_deployed(
    pool, mock_line, admin, me, base_asset,
    deposited, withdrawn, timespan,
    _add_credit, _get_position, _repay,
):
    og_pool_assets = pool.totalAssets()
    facility_fee = 1000 # 10%
    drawn_fee = 0
    id = _add_credit(deposited, drawn_fee, facility_fee)
    new_pool_balance = og_pool_assets + deposited
    p = _get_position(mock_line, id)

    assert p['deposit'] == deposited

    boa.env.time_travel(seconds=timespan)
    mock_line.accrueInterest(id)
    
    p2 = _get_position(mock_line, id)
    expected_interest = p2['interestAccrued']
    assert pool.totalAssets() == new_pool_balance
    assert p2['interestAccrued'] == expected_interest
    assert p2['interestRepaid'] == 0

    _repay(mock_line, id, expected_interest)

    if withdrawn > deposited + expected_interest: # cant withdraw more than is in line
        with boa.reverts(): # TODO test custom revert
            (withdrawn_deposit, withdraw_interest) = pool.reduce_credit(mock_line, id, withdrawn, sender=admin)
    else:
        (withdrawn_deposit, withdraw_interest) = pool.reduce_credit(mock_line, id, withdrawn, sender=admin)
        if withdrawn < expected_interest:
            expected_interest = withdrawn

        new_pool_assets = pool.totalAssets()
        assert withdrawn_deposit == withdrawn - expected_interest
        assert withdraw_interest == expected_interest
        assert pool.total_deployed() == new_pool_balance + expected_interest - withdrawn
        assert new_pool_assets == new_pool_balance + expected_interest
        assert pool.locked_profits() == expected_interest # no matter the vesting_rate MUST have 100% at block of collection
        
        if timespan == 0: # if no time, ensure we only updated total_deployed
            assert expected_interest == 0
            assert og_pool_assets + deposited == new_pool_assets
        # assert pool.last_report() == boa.env.???()  # no matter the vesting_rate MUST have 100% at block of collection

@pytest.mark.pool
@pytest.mark.line_integration
@given(deposited=st.integers(min_value=10**18, max_value=10**25),
        borrowed=st.integers(min_value=10**12, max_value=10**18),
        withdrawn=st.integers(min_value=10**18, max_value=10**25),)
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_cant_reduce_credit_when_deposit_borrowed(
    pool, mock_line, admin, me, base_asset,
    _add_credit, _get_position, _repay,
    deposited, withdrawn, borrowed
):
    facility_fee = 1000 # 10%
    id = _add_credit(deposited, 0, facility_fee)
    p = _get_position(mock_line, id)

    assert p['deposit'] == deposited
    mock_line.borrow(id, borrowed)

    if withdrawn > deposited - borrowed:
        with boa.reverts():
            pool.reduce_credit(mock_line, id, withdrawn, sender=admin)
    else: 
        pool.reduce_credit(mock_line, id, withdrawn, sender=admin)



@pytest.mark.pool
@pytest.mark.line_integration
def test_pool_can_open_multiple_lending_positions(
    pool, mock_line, my_line, admin, me, base_asset,
    _add_credit, _get_position, _repay,
):
    """
    necessarily implies can invest in multiple lines bc is constrained to
    1 position per line with line's position id generator algo
    """
    facility_fee = 1000 # 10%
    drawn_fee = 0 # 10%
    id = _add_credit(INIT_USER_POOL_BALANCE, 0, facility_fee)
    p = _get_position(mock_line, id)

    assert p['deposit'] == INIT_USER_POOL_BALANCE
    assert pool.total_deployed() == INIT_USER_POOL_BALANCE

    id2 = _add_credit(INIT_USER_POOL_BALANCE, 0, facility_fee, line=my_line)
    
    p2 = _get_position(my_line, id2)
    assert p2['deposit'] == INIT_USER_POOL_BALANCE
    assert pool.total_deployed() == INIT_USER_POOL_BALANCE * 2


@pytest.mark.pool
@pytest.mark.loss
@pytest.mark.line_integration
def test_impair_only_insolvent_lines(pool, base_asset, mock_line, _get_position, _add_credit):
    id = _add_credit(100)
    mock_line.borrow(id, 100)

    with boa.reverts(): # TODO TEST custom errors
        pool.impair(mock_line, id)

    mock_line.declareInsolvent()
    pool.impair(mock_line, id)

    
@pytest.mark.pool
@pytest.mark.loss
@pytest.mark.line_integration
def test_impair_only_callable_once(pool, base_asset, admin, mock_line, _get_position, _add_credit, _repay):
    id = _add_credit(100)
    mock_line.borrow(id, 100)

    with boa.reverts(): # TODO TEST custom errors
        pool.impair(mock_line, id)

    mock_line.declareInsolvent()
    pool.impair(mock_line, id)

    with boa.reverts(): # TODO TEST custom errors
        # self.impairments[line] will be > 0 so assert fails
        pool.impair(mock_line, id)
    
    # cant call impair() again even to recoup funds
    p = _get_position(mock_line, id)
    print(f"p pre pay {p}")
    _repay(mock_line, id, 100)
    p2 = _get_position(mock_line, id)
    print(f"p pre pay {p2}")
    with boa.reverts(): # TODO TEST custom errors
        # self.impairments[line] will be > 0 so assert fails
        pool.impair(mock_line, id)
    
    principal, interest = pool.reduce_credit(mock_line, id, MAX_UINT, sender=admin)
    assert principal == 100
    assert interest == 0


@pytest.mark.pool
@pytest.mark.loss
@pytest.mark.line_integration
def test_impair_callable_by_anyone(pool, base_asset, mock_line, admin, me, _add_credit, _increase_credit, _get_position):
    def run_test(caller):
        pool.eval(f"self.impairments[{mock_line.address}] = 0")
        pool.eval(f"self.total_supply = 0")
        pool.eval(f"self.total_assets = 0")
        mock_line.reset_position(id)

        id = _add_credit(INIT_POOL_BALANCE)
        assert base_asset.balanceOf(pool) == INIT_POOL_BALANCE
        mock_line.borrow(id, 100)
        mock_line.declareInsolvent()

        pool.impair(mock_line, id, sender=caller)
        assert pool.impairments(mock_line) == 100
        assert pool.total_deployed() == 100
        assert base_asset.balanceOf(pool) == INIT_POOL_BALANCE + INIT_POOL_BALANCE - 100


    run_test(me)
    run_test(admin)
    run_test(boa.env.generate_address())

@pytest.mark.pool
@pytest.mark.loss
@pytest.mark.line_integration
def test_impair_with_no_loss_reverts(pool, base_asset, mock_line, admin, me, _get_position, _add_credit):
    id = _add_credit(INIT_POOL_BALANCE)
    
    position =_get_position(mock_line, id)
    assert position['deposit'] == INIT_POOL_BALANCE
    assert position['principal'] == 0
    assert position['interestRepaid'] == 0
    assert position['interestAccrued'] == 0

    mock_line.declareInsolvent()
    with boa.reverts(): # TODO TEST custom errors
        pool.impair(mock_line, id, sender=me)


@pytest.mark.pool
@pytest.mark.loss
@pytest.mark.line_integration
def test_reduce_credit_on_insolvent_line_with_interest(
    pool, mock_line, base_asset, admin, me,
    _get_position, _repay, _collect_interest, _increase_credit
):
    interest, id = _collect_interest(INIT_POOL_BALANCE, DRATE, FRATE, INTEREST_TIMESPAN_SEC)
    profit_logs = pool.get_logs()
    perf_rev_event = _find_event_by({ 'fee_type': 1 }, profit_logs)
    collect_rev_event = _find_event_by({ 'fee_type': 16 }, profit_logs)
    assert pool.accrued_fees() == perf_rev_event['revenue']
    assert base_asset.balanceOf(pool) == interest
    
    mock_line.declareInsolvent()
    with boa.reverts():
        # impair fails bc no principal on the position
        pool.impair(mock_line, id, sender=me)
    
    boa.env.time_travel(INTEREST_TIMESPAN_SEC)
    mock_line.accrueInterest(id)
    interest2 = _get_position(mock_line, id)['interestAccrued']
    _repay(mock_line, id, interest2)

    pool.reduce_credit(mock_line, id, MAX_UINT, sender=admin)
    new_events = pool.get_logs()
    print("------------------")
    print(f"newevents {new_events}")
    new_perf_rev_event = _find_event_by({ 'fee_type': 1 }, new_events)
    new_collect_rev_event = _find_event_by({ 'fee_type': 16 }, new_events)
    new_total_deposits = interest + interest2 + INIT_POOL_BALANCE
    new_rev = (_to_shares(interest2) * pool.eval('self.fees.performance')) / FEE_COEFFICIENT
    total_fees = perf_rev_event['revenue'] + new_rev
    assert base_asset.balanceOf(pool) == new_total_deposits

    assert to_checksum_address(new_perf_rev_event['payer']) == pool.address
    assert new_perf_rev_event['receiver'] == admin
    assert to_checksum_address(new_perf_rev_event['token']) == pool.address
    assert new_perf_rev_event['amount'] < interest2 # less bc minflation reduces share price
    assert new_perf_rev_event['revenue'] == new_rev
    
    assert to_checksum_address(new_collect_rev_event['payer']) == pool.address
    assert new_collect_rev_event['receiver'] == me
    assert to_checksum_address(new_collect_rev_event['token']) == base_asset.address
    assert new_collect_rev_event['amount'] == interest
    assert new_collect_rev_event['revenue'] == 0
    
    assert pool.impairments(mock_line) == 0
    assert pool.accrued_fees() == perf_rev_event['revenue'] + new_perf_rev_event['revenue']
    assert pool.locked_profit() == interest
    assert pool.total_assets() == new_total_deposits + interest + interest2 - collect_rev_event['revenue']
    assert pool.total_supply() == new_total_deposits + total_fees
    assert pool.total_deployed() == 0
    
    # TODO TEST interesting that price goes down immediately after collecting profit bc
    # profit is locked but we pay immediately to caller
    assert pool.vault_assets() == new_total_deposits - collect_rev_event['revenue']
    
    position = _get_position(mock_line, id)
    assert position['deposit'] == 0
    assert position['principal'] == 0
    assert position['interestRepaid'] == 0
    assert position['interestAccrued'] == 0


@pytest.mark.pool
@pytest.mark.loss
@pytest.mark.line_integration
@given(borrowed=st.integers(min_value=1, max_value=10**25),
       perf_fee=st.integers(min_value=1, max_value=FEE_COEFFICIENT),)
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_impair_with_loss_plus_interest(
    pool, mock_line, admin, me, base_asset,
    borrowed, perf_fee,
    _get_position, _repay, _collect_interest, _increase_credit
):
    print(f"------------------------")
    pool.set_performance_fee(perf_fee, sender=admin)
    interest, id = _collect_interest(INIT_POOL_BALANCE, DRATE, FRATE, INTEREST_TIMESPAN_SEC)
    # get event before boa wipes on next tx
    profit_logs = pool.get_logs()
    # print(f"+ loss + interest events -- {profit_logs}")
    perf_rev_event = _find_event_by({ 'fee_type': 1 }, profit_logs)


    # interest claimed was higher than debt impaired
    # perf + collector rev generated 
    init_fees = perf_rev_event['revenue']
    assert to_checksum_address(perf_rev_event['payer']) == pool.address
    assert to_checksum_address(perf_rev_event['receiver']) == admin
    assert to_checksum_address(perf_rev_event['token']) == pool.address
    # maybe use updated pool price instead of stale one
    assert perf_rev_event['amount'] == interest # more shares bc minflation reduces price
    assert pool.accrued_fees() == init_fees
    assert init_fees > 0
    print(f"POOL FEES #1 {pool.accrued_fees()}/{init_fees}")
    # or `if lost > interest >= shares else <= shares`` bc minflation affects price

    # if borrowed > interest:
    # else:
    #     assert perf_rev_event['amount'] <= interest # more shares bc minflation reduces price

    # if rounding error, do diff in accrued_fees btw interest
    # subtract principal repaid from interest
    # NOTE: pool converst to assets to shares  before calculating fees
    # TODO TEST rounding error
    # assert perf_rev_event['revenue'] == math.floor((_to_shares(interest, pool.price()) * perf_fee) / FEE_COEFFICIENT)
        

    mock_line.borrow(id, borrowed)
    mock_line.declareInsolvent()
    print(f"Profit Event {perf_rev_event}")
    
     # accrue interest again on call to test proper fees math on burn + rev reporting
    boa.env.time_travel(INTEREST_TIMESPAN_SEC)
    mock_line.accrueInterest(id)
    position = _get_position(mock_line, id)
    print(f"position w/ in {position}")
    interest_earned = _get_position(mock_line, id)['interestAccrued']
    _repay(mock_line, id, interest_earned)
    vested_profits = pool.unlock_profits() # vesting early willhave same price as if they vested inside impair()
    share_price = pool.price() # store pool price before impairing
    assets_lost, fees_burned = pool.impair(mock_line, id, sender=me)
    impair_logs = pool.get_logs()
    print(f"+ loss + interest events -- {impair_logs}")

    print(
        "impair helper events",
        _find_event_by({ 'str': "fees_shares_burn" }, impair_logs),
        _find_event_by({ 'str': "fee_assets_burned" }, impair_logs),
        _find_event_by({ 'str': "total_to_burn" }, impair_logs),
        _find_event_by({ 'str': "pool_assets_lost" }, impair_logs),
    )

    impair_event = _find_event('Impair', impair_logs).args_map
    perf_rev_event2 = _find_event_by({ 'fee_type': 1 }, profit_logs)
    net_loss = borrowed - interest_earned
    impair_perf_fees = 0
    if net_loss < 0: # made more in interest than we lost to borrower
        impair_perf_fees = perf_rev_event2['revenue']
        # TODO TEST only 1 fee is accounted for even if 0 burned
        # assert pool.accrued_fees() == init_fees + impair_perf_fees - fees_burned
        assert perf_rev_event2 is not None
        assert assets_lost == 0
        assert fees_burned == 0
        assert to_checksum_address(perf_rev_event2['payer']) == pool.address
        assert to_checksum_address(perf_rev_event2['receiver']) == admin
        assert to_checksum_address(perf_rev_event2['token']) == pool.address
        # TODO TEST. kinda hard to calc. price changesafter _collect_interest at start
        # assert to_checksum_address(perf_rev_event2['amount']) == pool.address
        # assert to_checksum_address(perf_rev_event2['revenue']) == pool.address
        assert impair_event['net_asset_loss'] == 0
        assert impair_event['fees_burned'] ==  0

        # profit is unlocked after we impair if still remaining
        assert pool.vault_assets() == INIT_POOL_BALANCE + vested_profits
    else:
        # cant earn fees on impaired lines enuless all principal repaid by interest
        assert pool.accrued_fees() == init_fees - fees_burned # perf/burn are 0 by default
        assert assets_lost == abs(net_loss)
        assert assets_lost == abs(net_loss)
        assert perf_rev_event is None
        # loss reduced by burning previously earned fees and interest we just collected
        init_fee_in_assetes =  _to_assets(init_fees)
        assert impair_event['net_asset_loss'] == net_loss - init_fee_in_assetes
        assert impair_event['fees_burned'] == init_fee_in_assetes
        assert pool.vault_assets() == INIT_POOL_BALANCE + net_loss


    print(f"Impair Event + loss + interest {impair_event}")
    assert impair_event['position'] == id
    assert to_checksum_address(impair_event['line']) == mock_line.address
    assert impair_event['realized_loss'] == borrowed
    assert impair_event['interest_earned'] == interest_earned
    assert impair_event['recovered_deposit'] == INIT_POOL_BALANCE - borrowed
    
    # assert impair_event['fees_burned'] == init_fees # TODO FIX  based on borrowed

    new_total_deposits = INIT_POOL_BALANCE
    new_total_assets = new_total_deposits - borrowed + interest + interest_earned
    assert base_asset.balanceOf(pool) == new_total_assets

    assert pool.impairments(mock_line) == borrowed
    # assert pool.locked_profits() == interest + interest_earned - borrowed if net_impair > 0 else 0
    assert pool.total_assets() == new_total_assets
    # TODO TEST only 1 fee is accounted for even if 0 burned
    # assert pool.total_supply() == new_total_deposits + init_fees + impair_perf_fees  - fees_burned
    assert pool.total_deployed() == borrowed


    # technically this tests line not pool but whatevs integration test
    position = _get_position(mock_line, id)
    assert position['deposit'] == borrowed
    assert position['principal'] == borrowed
    assert position['interestRepaid'] == 0
    assert position['interestAccrued'] == 0

@pytest.mark.pool
@pytest.mark.loss
@pytest.mark.line_integration
@given(deposited=st.integers(min_value=10**25, max_value=10**34),
       borrowed=st.integers(min_value=1, max_value=10**25),)
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_impair_with_loss(
    pool, base_asset, mock_line, admin, me,
    deposited, borrowed, init_token_balances,
    _add_credit, _get_position
):
    assert base_asset.balanceOf(pool) == INIT_POOL_BALANCE # clean start
    pool.eval('self.accrued_fees = 0')
    id = _add_credit(deposited)
    assert base_asset.balanceOf(pool) == INIT_POOL_BALANCE # in line
    mock_line.borrow(id, borrowed)
    mock_line.declareInsolvent()
    pool.impair(mock_line, id, sender=me)
    impair_logs = pool.get_logs()
    impair_event = _find_event('Impair', impair_logs).args_map
    expeted_recovered = deposited - borrowed
    new_total_assets =  INIT_POOL_BALANCE + expeted_recovered

    assert impair_event['position'] == id
    assert to_checksum_address(impair_event['line']) == mock_line.address
    assert impair_event['net_asset_loss'] == borrowed
    assert impair_event['realized_loss'] == borrowed
    assert impair_event['interest_earned'] == 0
    assert impair_event['recovered_deposit'] == expeted_recovered
    assert impair_event['fees_burned'] == 0


    assert base_asset.balanceOf(pool) == new_total_assets
    assert pool.impairments(mock_line) == borrowed
    assert pool.accrued_fees() == 0
    assert pool.locked_profits() == 0
    assert pool.total_assets() == new_total_assets
    assert pool.total_supply() == INIT_POOL_BALANCE + deposited
    assert pool.total_deployed() == borrowed
    # assert pool.price() == _calc_price(new_total_assets, deposited) # TODO TEST fix rounding error

    # profit is locked but we pay immediately to caller
    assert pool.vault_assets() == new_total_assets

    
    position = _get_position(mock_line, id)
    assert position['deposit'] == borrowed
    assert position['principal'] == borrowed
    assert position['interestRepaid'] == 0
    assert position['interestAccrued'] == 0


@pytest.mark.pool
@pytest.mark.loss
@pytest.mark.line_integration
def test_impair_all_pool_assets(
    pool, base_asset, mock_line, admin, me,
    _add_credit, _get_position
):
    id = _add_credit(INIT_POOL_BALANCE)
    mock_line.borrow(id, INIT_POOL_BALANCE)
    # no interest earned so we can lose impair principal amount
    mock_line.declareInsolvent()
    pool.impair(mock_line, id, sender=me)
    impair_logs = pool.get_logs()
    impair_event = _find_event('Impair', impair_logs).args_map
    perf_rev_event = _find_event_by({'fee_type': 1}, impair_logs)


    assert impair_event['position'] == id
    assert to_checksum_address(impair_event['line']) == mock_line.address
    assert impair_event['net_asset_loss'] == INIT_POOL_BALANCE
    assert impair_event['realized_loss'] == INIT_POOL_BALANCE
    assert impair_event['interest_earned'] == 0
    assert impair_event['recovered_deposit'] == 0
    assert impair_event['fees_burned'] == 0

    assert base_asset.balanceOf(pool) == INIT_POOL_BALANCE

    assert pool.impairments(mock_line) == INIT_POOL_BALANCE
    assert pool.accrued_fees() == 0
    assert pool.locked_profits() == 0
    assert pool.total_assets() == 0
    assert pool.total_supply() == INIT_POOL_BALANCE
    assert pool.total_deployed() == INIT_POOL_BALANCE
    assert pool.price() == POOL_PRICE_DECIMALS

    # profit is locked but we pay immediately to caller
    assert pool.vault_assets() == 0

    position = _get_position(mock_line, id)
    assert position['deposit'] == INIT_POOL_BALANCE
    assert position['principal'] == INIT_POOL_BALANCE
    assert position['interestRepaid'] == 0
    assert position['interestAccrued'] == 0

### Pool Lender Tests

# (done) only owner can call add_credit
# (done) only owner can call increase_credit
# (done) only owner can call set_rates
# (done) only owner can call reduce_credit
# (done) Pool MUST be able to open multiple positions on different lines.
# (done) add_credit to line increases total_deployed
# (done) increase_credit to line increases total_deployed
# (done) reduce_credit with max uint pulls all funds
# (done) collecting profit multiple times stacks on top of each other in locked_profit
# (done) cant reduce credit if funds borrowed
# (done) collect_interest to pool increases total assets and locked profit
# (done) reduce_credit cant pull more funds than in position
# (done) reduce_credit with interest increases total assets and locked profit and decreases total deployed


# (done) can only impair if line is insolvent
# (done) anyone can impair incl owner
# (done) cant impair with no principal loss 
# cannot impair the same position id twice (error on line not pool)
# reduce impaired amount when we receive principal repayment after
# (done) collect_interest then impair burns fees 
# (done) impair (+ claim interest)
# (done) impair w/ accrued_fees
# (done) impair no accrued_fees
# (done) impairing all assets (total_deployed) brings share price to 0
# - test multi invest + divest - 
# properly divest -  no profit, profit, loss, profit, no profit, profit, loss (to 0 then invest again), profit
# properly impair - loss, profit (2x),


# major internal funcs
# (done via collect_interest) _reduce_credit with 0 will only withdraw available interest (test withdrawable, 
# (done) _reduce_credit with MAX_UINT will withdraw all available funds


### Pool Borrower Tests

# pool MUST borrow from line where they are borrower
# ??y/n?? pool MUST NOT be able to post collateral to loans
# 
# cannot borrow from a position that isnt denominated in pool ASSET
# Pool MUST repay all debt if total_assets are available and they are in  DEFUALT/INSOLVENT status
# anyone can call emergency_repay to repay debt on defaulted lines
# emergency_repay MUST NOT work on ACTIVE lines
# emergency_repay MUST slash accrued_fees and pool assets if successful
# Pool MUST be able to open multiple positions per line. 
# Pool MUST be able to own multiple lines. 
# Pool can only borrow from one lender per line. Line constraint bc can only borrow ASSET, lender can only create one position per line.
# MUST be able to track initial principal drawn vs repaid
# MUST be able to track initial interest owed on a line


# Can impair on a position with 0 debt
# Impairing position with 0 debt MUST NOT reduce locked_profit, total_assets, or accrued_fees
# Impairing position with 0 debt MUST be successful if a non-0 debt call would succeed
# 


# MUST NOT repay debt to line where pool isnt borrower
# Pool shareholders MUST NOT redeem debt assets, only users deposits
# MUST be able to use debt assets to invest into LoC 
# MUST be able to use debt assets to invest into vaults
# 

# can make a Spigot rev_recipient
# can make a Spigot owner
# Spigot rev_recipient can claim_rev via claimRevenue
# Spigot can whitelist() Pool owner funcs
# Spigot can operate() Pool owner funcs

# 
# can addCollateral to line escrow
# can only addCollateral from liquid total_assets
# 1. addCollateral increases self.total_deployed
# 1. addCollateral reduces self.total_assets


