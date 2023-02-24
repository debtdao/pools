import boa
import ape
import math
import pytest
from boa.vyper.contract import BoaError, VyperContract
from hypothesis import given, settings
from hypothesis import strategies as st
from hypothesis.stateful import RuleBasedStateMachine, run_state_machine_as_test, rule, invariant
from datetime import timedelta
from ..utils.events import _find_event
from ..conftest import INIT_USER_POOL_BALANCE, INIT_POOL_BALANCE, MAX_UINT

ONE_YEAR_IN_SEC=60*60*24*365.25
BYTES32_STRING = 0x0000000000000000000000000000000000000000000000000000000000000000
INTEREST_RATE_COEFFICIENT = 315576000000
INTEREST_TIMESPAN_SEC = int(ONE_YEAR_IN_SEC / 12)



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

    assert position['lender'] == pool.address
    assert position['deposit'] == amount
    assert position['token'] == base_asset.address
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

    assert position['lender'] == pool.address
    assert position['deposit'] == amount
    assert position['token'] == base_asset.address
    assert base_asset.balances(pool) == start_balance + amount
    assert base_asset.balances(mock_line) == amount

    pool.increase_credit(mock_line, id, amount, sender=admin)

    position2 = _get_position(mock_line, id)

    assert position2['lender'] == pool.address
    assert position2['deposit'] == amount * 2
    assert position2['token'] == base_asset.address
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
    assert position['lender'] == pool.address
    assert position['token'] == base_asset.address
    
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

    _repay(id, 1)

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
    _repay(id, expected_interest - 100)

    collected =  pool.collect_interest(mock_line, id)
    assert collected == expected_interest - 100
    assert pool.totalAssets() == INIT_POOL_BALANCE + amount + expected_interest - 100
    assert pool.locked_profits() == expected_interest - 100 # no matter the vesting_rate MUST have 100% at block of collection
    
    _repay(id, 100)

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

    _repay(id, expected_interest)
    
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

    _repay(id, expected_interest)

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

    _repay(id, expected_interest)
    
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
    id = _add_credit(100, 0, 0)

    with boa.reverts():
        pool.reduce_credit(mock_line, id, 10_000, sender=me)
    with boa.reverts():
        pool.reduce_credit(mock_line, id, 0, sender=me) # should still revert if no state change

    pool.reduce_credit(mock_line, id, 0, sender=admin)


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

    _repay(id, expected_interest)
    
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

    _repay(id, expected_interest)

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
        assert pool.total_deployed() == new_pool_balance - withdrawn + expected_interest
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


