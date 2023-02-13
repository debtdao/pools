import boa
import ape
import math
import pytest
from eth_utils import to_checksum_address
from boa.vyper.contract import BoaError
from hypothesis import given, settings
from hypothesis import strategies as st
from hypothesis.stateful import RuleBasedStateMachine, run_state_machine_as_test, rule, invariant
from datetime import timedelta
from ..utils.events import _find_event

MAX_UINT = 115792089237316195423570985008687907853269984665640564039457584007913129639935
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
ZERO_BYTES32 = "0x0000000000000000000000000000000000000000000000000000000000000000"
ClaimRevenueEventLogIndex = 2 # log index of ClaimRevenue event inside claim_rev logs (approve, transfer, claim, price)
MAX_PITANCE_FEE = 200 # 2% in bps
FEE_COEFFICIENT = 10000 # 100% in bps
SET_FEES_TO_ZERO = "self.fees = Fees({performance: 0, deposit: 0, withdraw: 0, flash: 0, collector: 0, referral: 0})"
VESTING_RATE_COEFFICIENT = 10**18
# TODO Ask ChatGPT to generate test cases in vyper
# 1. delegate priviliges on investment functions
# 1. vault_investment goes up by _amount 
# 1. only vault that gets deposited into has vault_investment changed
# 1. emits InvestVault event X params
# 1. emits RevenueGenereated event with X params and FEE_TYPES.DEPOSIT
# 1. investing in vault increased total_deployed by _amount
# 1. investing in vault increases vault.balanceOf(pool) by shares returned in vault.deposit
# 1. investing in vault increases vault.balanceOf(pool) by expected shares using _amount and pre-deposit share price
# 1. 
# 1. divesting vault decreases total_deployed
# 1. divesting vault 
# 1. emits DivestVault event with X params
# 1. emits RevenueGenereated event with X params and FEE_TYPES.WITHDRAW
# 1. divesting vault decreases vault.balanceOf(pool)
# 1. divesting vault decreases vault.balanceOf(pool) by shares returned in vault.withdraw
# 1. divesting vault decreases vault.balanceOf(pool) by expected shares using _amount and pre-withdraw share price

# 1. (done) fee updates in state
# 1. (done) fee update emits SetXFee event with X params and FEE_TYPES.Y
# 1. fee updates affect deposit/withdraw pricing
# 1. fees emitted properly in RevenueGenerated

# major internal funcs
# 1. _reduce_credit with 0 will only withdraw available interest (test withdrawable, )

# @settings(max_examples=500, deadline=timedelta(seconds=1000))
# def test_owner_fees_burned_on_impairment(pool, me, admin):
    # with boa.prank(me):
        # pool


def test_assert_pool_constants(pool):
    """
    Test hardcoded constants in contract are what they're supposed to be
    """
    assert pool.FEE_COEFFICIENT() == 10000  # 100% in bps
    assert pool.SNITCH_FEE() == 3000        # 30% in bps
    # @notice 5% in bps. Max fee that can be charged for non-performance fee
    assert pool.MAX_PITTANCE_FEE() == 200   # 2% in bps
    assert pool.CONTRACT_NAME() == 'Debt DAO Pool'
    assert pool.API_VERSION() == '0.0.001'  # dope that we can track contract version vs test for that version in source control
    # assert pool.DOMAIN_TYPE_HASH() == 0
    # assert pool.PERMIT_TYPE_HASH() == 0
    assert pool.VESTING_RATE_COEFFICIENT() == 1e18

def test_assert_initial_pool_state(pool, base_asset, admin):
    """
    Test inital state of dummy testing pool contract.
    """
    assert pool.fees() == ( 0, 0, 0, 0, 0, 0 )
    assert pool.accrued_fees() == 0
    assert pool.min_deposit() == 0
    assert pool.total_deployed() == 0
    assert pool.ASSET() == base_asset.address
    # ensure ownership and revenue is initialized properly
    assert pool.owner() == admin
    assert pool.pending_owner() == ZERO_ADDRESS
    assert pool.rev_recipient() == admin
    assert pool.pending_rev_recipient() == ZERO_ADDRESS
    assert pool.max_assets() == MAX_UINT
    # ensure profit logic is initialized properly
    assert pool.locked_profits() == 0
    assert pool.vesting_rate()== 46000000000000 # default eek
    assert pool.last_report() == pool.eval('block.timestamp')
    # ensure vault logic is initialized properly
    assert pool.totalSupply() == 0
    assert pool.total_assets()== 0


############################################
########                            ########
########  Pool Owner Functionality  ########
########                            ########
############################################
@pytest.mark.pool
@pytest.mark.pool_owner
def test_only_owner_can_set_max_asset(pool, admin, me):
    assert pool.max_assets() == MAX_UINT
    pool.set_max_assets(0, sender=admin)
    assert pool.max_assets() == 0
    pool.set_max_assets(0, sender=admin)
    assert pool.max_assets() == 0
    pool.set_max_assets(MAX_UINT, sender=admin)
    assert pool.max_assets() == MAX_UINT
    
    # pool depositor cant set limit
    with boa.reverts():
        pool.set_max_assets(MAX_UINT, sender=me)
    with boa.reverts():
        pool.set_max_assets(0, sender=me)
    with boa.reverts():
        pool.set_max_assets(10*10**18, sender=me)

    # rando cant set limit
    rando = boa.env.generate_address()
    with boa.reverts():
        pool.set_max_assets(MAX_UINT, sender=rando)
    with boa.reverts():
        pool.set_max_assets(0, sender=rando)
    with boa.reverts():
        pool.set_max_assets(10*10**18, sender=rando)
        
@pytest.mark.pool
@pytest.mark.pool_owner
@given(amount=st.integers(min_value=1, max_value=MAX_UINT - 1),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_fuzz_set_max_assets_amount(pool, base_asset, admin, me, amount):
    assert pool.max_assets() == MAX_UINT
    pool.set_max_assets(amount, sender=admin)
    assert pool.max_assets() == amount

    assert pool.total_assets() == 0 # ensure clean state
    base_asset.mint(me, amount + 1, sender=me) # do + 1 to test max overflow
    base_asset.approve(pool, amount + 1, sender=me)
    pool.deposit(amount, me, sender=me) # up to limit should work

    with boa.reverts():
        pool.deposit(1, me, sender=me) # 1 over limit


@pytest.mark.pool
@pytest.mark.pool_owner
def test_only_owner_can_set_min_deposit(pool, admin, me):
    assert pool.min_deposit() == 0
    pool.set_min_deposit(MAX_UINT, sender=admin)
    assert pool.min_deposit() == MAX_UINT
    pool.set_min_deposit(0, sender=admin)
    assert pool.min_deposit() == 0
    pool.set_min_deposit(10*10**18, sender=admin)
    assert pool.min_deposit() == 10*10**18
    
    # pool depositor cant set limit
    with boa.reverts():
        pool.set_min_deposit(MAX_UINT, sender=me)
    with boa.reverts():
        pool.set_min_deposit(0, sender=me)
    with boa.reverts():
        pool.set_min_deposit(10*10**18, sender=me)

    # rando cant set limit
    rando = boa.env.generate_address()
    with boa.reverts():
        pool.set_min_deposit(MAX_UINT, sender=rando)
    with boa.reverts():
        pool.set_min_deposit(0, sender=rando)
    with boa.reverts():
        pool.set_min_deposit(10*10**18, sender=rando)
        

@pytest.mark.pool
@pytest.mark.pool_owner
@given(amount=st.integers(min_value=1, max_value=MAX_UINT / 3),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_fuzz_set_min_deposit_amount(pool, base_asset, admin, me, amount):
    assert pool.min_deposit() == 0
    pool.set_min_deposit(amount, sender=admin)
    assert pool.min_deposit() == amount

    assert pool.total_assets() == 0 # ensure clean state
    base_asset.mint(me, amount, sender=me) # do + 1 to test max overflow
    base_asset.approve(pool, amount, sender=me)

    with boa.reverts():
        pool.deposit(amount - 1, me, sender=me) # under min fails

    pool.deposit(amount, me, sender=me) # up to limit should work

    base_asset.mint(me, amount * 2, sender=me) # do + 1 to test max overflow
    base_asset.approve(pool, amount * 2, sender=me)
    pool.deposit(amount * 2, me, sender=me) # over limit should work


@pytest.mark.pool
@pytest.mark.pool_owner
def test_only_owner_can_set_vesting_rate(pool, admin, me):
    assert pool.vesting_rate() == 46000000000000
    pool.set_vesting_rate(VESTING_RATE_COEFFICIENT, sender=admin)
    assert pool.vesting_rate() == VESTING_RATE_COEFFICIENT
    pool.set_vesting_rate(0, sender=admin)
    assert pool.vesting_rate() == 0
    pool.set_vesting_rate(VESTING_RATE_COEFFICIENT - 10**10, sender=admin)
    assert pool.vesting_rate() == VESTING_RATE_COEFFICIENT - 10**10
    
    # pool depositor cant set limit
    with boa.reverts():
        pool.set_vesting_rate(VESTING_RATE_COEFFICIENT, sender=me)
    with boa.reverts():
        pool.set_vesting_rate(0, sender=me)
    with boa.reverts():
        pool.set_vesting_rate(VESTING_RATE_COEFFICIENT - 10**10, sender=me)

    # rando cant set limit
    rando = boa.env.generate_address()
    with boa.reverts():
        pool.set_vesting_rate(VESTING_RATE_COEFFICIENT, sender=rando)
    with boa.reverts():
        pool.set_vesting_rate(0, sender=rando)
    with boa.reverts():
        pool.set_vesting_rate(VESTING_RATE_COEFFICIENT - 10**10, sender=rando)
        

@pytest.mark.pool
@pytest.mark.pool_owner
@given(amount=st.integers(min_value=1, max_value=10**18),) # max = DEGRADATAION_COEFFECIENT
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_fuzz_set_vesting_rate_amount(pool, base_asset, admin, me, amount):
    assert pool.vesting_rate() == 46000000000000

    if amount > VESTING_RATE_COEFFICIENT:
        with boa.reverts():
            pool.set_vesting_rate(amount, sender=admin)
    else:
        pool.set_vesting_rate(amount, sender=admin)
        assert pool.vesting_rate() == amount
    
    # profit lock tests have their own section below in this file

############################################%#
########                              ########
########  Revenue Generator EIP Impl  ########
########                              ########
############################################%#
@pytest.mark.pool
@pytest.mark.rev_generator
@given(pittance_fee=st.integers(min_value=1, max_value=MAX_PITANCE_FEE),
        perf_fee=st.integers(min_value=1, max_value=FEE_COEFFICIENT),
        amount=st.integers(min_value=1, max_value=10**25),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_revenue_calculations_based_on_fees_state(
    pool, pool_fee_types, admin, me, base_asset, pittance_fee, perf_fee, amount
):
    null_fees = dict(zip(pool_fee_types, (0,)*len(pool_fee_types)))
    for fee_type in pool_fee_types:
         # reset all fees so they dont pollute test. have separete test for composite fees
        pool.eval(SET_FEES_TO_ZERO)
        _deposit(pool, base_asset, me, amount)
        assert pool.accrued_fees() == 0

        set_fee = getattr(pool, f'set_{fee_type}_fee', lambda x: "Fee type does not exist in Pool.vy")
        fee_bps = pittance_fee if _is_pittance_fee(fee_type) else perf_fee
        expected_rev = (amount * fee_bps) / FEE_COEFFICIENT
        if expected_rev < 1:
            expected_rev = 0
        else:
            expected_rev = math.floor(expected_rev)

        expected_recipient = admin

        # print("test fee rev generation", fee_bps, amount, expected_rev, fee_type)

        set_fee(fee_bps, sender=admin) # set fee so we generate revenue
        assert fee_bps == pool.eval(f'self.fees.{fee_type}')
        _deposit(pool, base_asset, me, amount)
        event = _find_event('RevenueGenerated', pool.get_logs())
        
        # TODO TEST - need to call right pool method to get right fees accrued like other tests
        # test fails bc we only accrue deposit/referral not withdraw, collector, or performance
        assert pool.accrued_fees() == expected_rev
        assert event.args_map['receiver'] == expected_recipient

        
@pytest.mark.pool
@pytest.mark.rev_generator
@given(pittance_fee=st.integers(min_value=1, max_value=MAX_PITANCE_FEE),
        perf_fee=st.integers(min_value=1, max_value=FEE_COEFFICIENT),
        amount=st.integers(min_value=1, max_value=10**25),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_revenue_calculations_with_multiple_fees(
    pool, pool_fee_types, admin, me, base_asset, pittance_fee, perf_fee, amount
):
    """
    only 3 conditions where this happens i think
    1. DEPOSIT + REFERRAL (_deposit)
    2. PERFORMANCE + COLLECTOR (_reduce_credit)
    3. COLLECTOR + SNITCH (_impair if INSOLVENT but we also claim interest)
    """

    # 1. DEPOSIT + REFERRAL - _deposit
    pool.eval(SET_FEES_TO_ZERO)
    pool.set_deposit_fee(pittance_fee, sender=admin)
    pool.set_referral_fee(pittance_fee, sender=admin)

    base_asset.mint(admin, amount)
    base_asset.approve(pool, amount, sender=admin)
    pool.deposit(amount, admin, sender=admin)
    [deposit_rev, referral_rev] = pool.get_logs()[0:1]
    assert deposit_rev.args_map['fee_type'] == 2
    assert deposit_rev.args_map['receiver'] == admin
    assert deposit_rev.args_map['payer'] == pool
    assert referral_rev.args_map['fee_type'] == 16
    assert referral_rev.args_map['receiver'] == ZERO_ADDRESS
    assert referral_rev.args_map['payer'] == pool

    # TODO check events emitted

    # 2. PERFORMANCE + COLLECTOR - _reduce_credit
    pool.eval(SET_FEES_TO_ZERO)
    pool.set_performance_fee(perf_fee, sender=admin)
    pool.set_collector_fee(pittance_fee, sender=admin)
    # TODO asset.mint(mock_line, amount)
    # TODO mock_line.eval('self.credits[{pool}] = Position({ deposit: 0, principal: 0, lender: 0, token: {asset}, interestAccrued: 0, interestRepaid: {amount}, isOpen: true })')
    # TODO pool.collect_interest(mock_line, pool)
    # TODO check events emitted


    #3.  SNITCH + COLLECTOR - _impair
    pool.eval(SET_FEES_TO_ZERO)
    pool.set_collector_fee(pittance_fee, sender=admin)
    # TODO mock_line.eval('self.credits[{pool}] = Position({ deposit: {amount}, principal: {amount / 2}, lender: 0, token: {asset}, interestAccrued: 0, interestRepaid: 0, isOpen: true })')
    # TODO pool.reduce_credit()
    # expect to lost = `amount / 2`
    # TODO check events emitted




@pytest.mark.pool
@pytest.mark.rev_generator
@pytest.mark.event_emissions
@given(amount=st.integers(min_value=1, max_value=10**25),
        pittance_fee=st.integers(min_value=1, max_value=MAX_PITANCE_FEE)) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_pittance_fees_emit_revenue_generated_event(pool, pittance_fee_types, admin, me, base_asset, pittance_fee, amount):
    total_accrued_fees = 0  # var accumulate fees across txs in loop
    for idx, fee_name in enumerate(pittance_fee_types):
        assert total_accrued_fees == pool.accrued_fees()

        fee_enum_idx = idx + 1
        fee_type_uint = 2**fee_enum_idx
        set_fee = getattr(pool, f'set_{fee_name}_fee', lambda x: "Fee type does not exist in Pool.vy")

        expected_rev = math.floor(((amount * pittance_fee) / FEE_COEFFICIENT))
        
        set_fee(pittance_fee, sender=admin) # set fee so we generate revenue
        _deposit(pool, base_asset, me, amount)

        
        # test deposit event before other pool state
        events = pool.get_logs()

        # Rev event placement changes based on `amount` value.
        rev_event_type = 'RevenueGenerated'
        e_types = [e.event_type.name for e in events]
        # Have multiple RevGenerated events based on function called.
        # deposit() emits DEPOSIT + REFERRAL, collect_interest() emits PERFORMANCE + COLLECTOR
        # they have predetermined ordering and are always called in same order
        event = events[e_types.index(rev_event_type)]

        # print("find rev eevent", event.event_type.name, rev_event_type, rev_event_type == event.event_type.name, rev_event_type in e_types, fee_type)
        assert f'{event.event_type.name}' == rev_event_type # double check
        assert event.args_map['amount'] == amount
        assert event.args_map['revenue'] == expected_rev

        match fee_name:
            case 'deposit':
                assert to_checksum_address(event.args_map['payer']) == pool.address
                assert to_checksum_address(event.args_map['token']) == pool.address
                assert to_checksum_address(event.args_map['receiver']) == admin
            case 'withdraw':
                assert to_checksum_address(event.args_map['payer']) == me
                assert to_checksum_address(event.args_map['token']) == pool 
                assert to_checksum_address(event.args_map['receiver']) == admin
            case 'referral':
                assert to_checksum_address(event.args_map['payer']) == pool
                assert to_checksum_address(event.args_map['token']) == pool 
                assert to_checksum_address(event.args_map['receiver']) == me
            case 'collector':
                assert to_checksum_address(event.args_map['payer']) == pool
                assert to_checksum_address(event.args_map['token']) == base_asset 
                assert to_checksum_address(event.args_map['receiver']) == me
            case 'snitch':
                assert to_checksum_address(event.args_map['payer']) == pool
                assert to_checksum_address(event.args_map['token']) == base_asset 
                assert to_checksum_address(event.args_map['receiver']) == me

        # check post deposit state after event so boa doesnt overwrite
        total_accrued_fees += expected_rev
        assert pool.accrued_fees() == total_accrued_fees

@pytest.mark.pool
@pytest.mark.rev_generator
def test_cant_set_pittance_fee_over_200_bps(pool, pittance_fee_types, admin):
    for fee_type in pittance_fee_types:
        set_fee = getattr(pool, f'set_{fee_type}_fee', lambda x: "Fee type does not exist in Pool.vy")
        with boa.reverts():
            set_fee(MAX_PITANCE_FEE + 1, sender=admin)

@pytest.mark.pool
@pytest.mark.rev_generator
@given(pittance_fee=st.integers(min_value=1, max_value=MAX_PITANCE_FEE)) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_can_set_pittance_fee_0_to_200_bps(pool, pittance_fee_types, admin, pittance_fee):
    for fee_type in pittance_fee_types:
        set_fee = getattr(pool, f'set_{fee_type}_fee', lambda x: "Fee type does not exist in Pool.vy")

        curr_fee = pool.eval(f'self.fees.{fee_type}')
        assert curr_fee == 0
        set_fee(pittance_fee, sender=admin)
        new_fee = pool.eval(f'self.fees.{fee_type}')
        assert new_fee == pittance_fee


@pytest.mark.pool
@pytest.mark.rev_generator
def test_cant_set_performance_fee_over_10000_bps(pool, admin):
    with boa.reverts():
        pool.set_performance_fee(FEE_COEFFICIENT + 1, sender=admin)


@pytest.mark.pool
@pytest.mark.rev_generator
@given(perf_fee=st.integers(min_value=1, max_value=FEE_COEFFICIENT))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_can_set_performance_fee_under_10000_bps(pool, admin, perf_fee):
    curr_fee = pool.eval(f'self.fees.performance')
    assert curr_fee == 0
    pool.set_performance_fee(perf_fee, sender=admin)
    new_fee = pool.eval(f'self.fees.performance')
    assert new_fee == perf_fee


# @pytest.mark.pool
# @pytest.mark.rev_generator
# @pytest.mark.event_emmissions
# @given(fee_bps=st.integers(min_value=1, max_value=MAX_PITANCE_FEE))
# @settings(max_examples=100, deadline=timedelta(seconds=1000))
# def test_cant_set_snitch_fee(pool, pool_fee_types, admin, fee_bps):
#     with boa.reverts(): # should revert bc changing constant
#     TODO figure out how to expect boa error not a tx revert for accessing constant
#         pool.eval('SNITCH_FEE = 0')

@pytest.mark.pool
@pytest.mark.rev_generator
@pytest.mark.event_emmissions
@given(fee_bps=st.integers(min_value=1, max_value=MAX_PITANCE_FEE))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_setting_fees_emits_standard_event(pool, pool_fee_types, admin, fee_bps):
    for idx, fee_type in enumerate(pool_fee_types):
        set_fee = getattr(pool, f'set_{fee_type}_fee', lambda x: "Fee type does not exist in Pool.vy")
        set_fee(fee_bps, sender=admin)

        event_name = 'FeeSet'
        event = _find_event(event_name, pool.get_logs())

        assert f'{event.event_type.name}' == event_name
        assert event.args_map['fee_bps'] == fee_bps
        assert event.args_map['fee_type'] == 2**idx # boa logs are exponential
        assert pool.fees()[idx] == fee_bps

def _deposit(pool, token, user, amount):
    token.mint(user, amount)
    token.approve(pool, amount, sender=user)
    pool.deposit(amount, user, sender=user)
    

def _is_pittance_fee(fee_name: str) -> bool:
    if fee_name:
        match fee_name:
            case 'performance':
                return False
            case _:
                return True
    # if fee_enum_idx:
    #     match fee_enum_idx:
    #         case 0: # performance
    #             return False
    #         case _:
    #             return True


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
def test_only_pool_owner_can_invest(pool, mock_line, admin, me, base_asset, init_token_balances):
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
@given(amount=st.integers(min_value=1, max_value=10**25),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_pool_can_deposit_to_line(pool, mock_line, admin, me, base_asset, init_token_balances, amount):
    start_balance = init_token_balances * 2
    base_asset.mint(me, amount)
    base_asset.approve(pool, amount, sender=me)
    pool.deposit(amount, me , sender=me)

    assert base_asset.balances(pool) == start_balance + amount
    assert base_asset.balances(mock_line) == 0
    
    id = pool.add_credit(mock_line, 0, 0, amount, sender=admin)

    (deposit, _, __, ___, _____, token, lender, _____) = mock_line.credits(id)

    assert lender == pool.address
    assert deposit == amount
    assert token == base_asset.address
    assert base_asset.balances(pool) == start_balance
    assert base_asset.balances(mock_line) == amount


@pytest.mark.pool
@pytest.mark.line_integration
@given(amount=st.integers(min_value=1, max_value=10**25),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_pool_can_increase_deposit_to_line(pool, mock_line, admin, me, base_asset, init_token_balances, amount):
    start_balance = init_token_balances * 2
    base_asset.mint(me, amount * 2)
    base_asset.approve(pool, amount * 2, sender=me)
    pool.deposit(amount * 2, me , sender=me)

    assert base_asset.balances(pool) == start_balance + amount * 2
    assert base_asset.balances(mock_line) == 0
    
    id = pool.add_credit(mock_line, 0, 0, amount, sender=admin)

    (deposit, _, __, ___, _____, token, lender, _____) = mock_line.credits(id)

    assert lender == pool.address
    assert deposit == amount
    assert token == base_asset.address
    assert base_asset.balances(pool) == start_balance + amount
    assert base_asset.balances(mock_line) == amount

    pool.increase_credit(mock_line, id, amount, sender=admin)

    (deposit, _, __, ___, _____, token, lender, _____) = mock_line.credits(id)

    assert lender == pool.address
    assert deposit == amount * 2
    assert token == base_asset.address
    assert base_asset.balances(pool) == start_balance
    assert base_asset.balances(mock_line) == amount * 2


@pytest.mark.pool
@pytest.mark.line_integration
@given(drate=st.integers(min_value=1, max_value=10**10),
        frate=st.integers(min_value=1, max_value=10**10),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_pool_can_change_rates_on_existing_position(pool, mock_line, admin, me, base_asset, drate, frate):
    amount = 1
    base_asset.mint(me, amount * 2)
    base_asset.approve(pool, amount * 2, sender=me)
    pool.deposit(amount * 2, me , sender=me)

    id = pool.add_credit(mock_line, 0, 0, amount, sender=admin)

    (deposit, _, __, ___, _____, token, lender, _____) = mock_line.credits(id)

    # ensure proper position for id
    assert lender == pool.address
    assert token == base_asset.address
    
    [drate, frate, _] = mock_line.rates(id)
    assert drate == 0 and frate == 0

    pool.set_rates(mock_line, id, drate, frate, sender=admin)

    [drate2, frate2, _] = mock_line.rates(id)
    assert drate2 == drate and frate2 == frate

    # can set back to 0
    pool.set_rates(mock_line, id, 0, 0, sender=admin)

    [drate2, frate2, _] = mock_line.rates(id)
    assert drate2 == 0 and frate2 == 0

@pytest.mark.pool
@pytest.mark.line_integration
@given(amount=st.integers(min_value=1, max_value=10**25),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_pool_can_change_rates_on_nonexistant_position(pool, mock_line, admin, me, base_asset, amount):
    with boa.reverts(): # error from line contract gets bubbled to Pool
        pool.set_rates(mock_line, id, 1_000, 100, sender=admin)



############################################%#
########                              ########
########  Locked Profit Calculations  ########
########                              ########
############################################%#

@pytest.mark.pool
@pytest.mark.slow
@given(total_profit=st.integers(min_value=10**18, max_value=MAX_UINT),
        vesting_time=st.integers(min_value=0, max_value=VESTING_RATE_COEFFICIENT * 2),
        vesting_rate=st.integers(min_value=0, max_value=VESTING_RATE_COEFFICIENT),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_calling_unlock_profit_releases_all_available_profit(
    pool, me, base_asset, total_profit, vesting_time, vesting_rate
):  
    base_asset.mint(pool, total_profit)
    pool.eval(f"""
        self.total_assets = {total_profit}
        self.locked_profits = {total_profit}
        self.vesting_rate = {vesting_rate}
    """)
    # last_report set at contract deployment in fixture so should be `now`

    # nothing should change until we call unlock_profit
    assert pool.locked_profits() == total_profit
    # max liquid assets is 0 bc all locked
    assert pool.maxFlashLoan(base_asset) == 0
    
    boa.env.time_travel(vesting_time)

    locked_profit = 0
    if vesting_time is 0 or vesting_rate is 0:
        locked_profit = total_profit
    elif vesting_time * vesting_rate >= VESTING_RATE_COEFFICIENT: # wrong condition. check vesting_rate vs coeeficient and time compared to that
        locked_profit = 0
    else:
         locked_profit = math.floor(total_profit - math.floor(((total_profit * vesting_time * vesting_rate) / VESTING_RATE_COEFFICIENT)))

    pool.unlock_profits()

    assert pool.locked_profits() == locked_profit
    # max liquid should include unlocked profits now
    assert pool.maxFlashLoan(base_asset) == total_profit - locked_profit

    
    