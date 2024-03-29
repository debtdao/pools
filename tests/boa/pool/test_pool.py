import boa
import ape
import math
import pytest
from eth_utils import to_checksum_address
from boa.vyper.contract import BoaError
from hypothesis import given, settings
from hypothesis import strategies as st
from hypothesis.stateful import RuleBasedStateMachine, run_state_machine_as_test, rule, invariant
from eth_utils import to_checksum_address
from datetime import timedelta
from ..utils.events import _find_event, _find_event_by
from ..utils.price import _calc_price, _to_assets, _to_shares
from .conftest import VESTING_RATE_COEFFICIENT, SET_FEES_TO_ZERO, DRATE, FRATE, INTEREST_TIMESPAN_SEC, ONE_YEAR_IN_SEC,  FEE_COEFFICIENT, MAX_PITTANCE_FEE
from ..conftest import MAX_UINT, ZERO_ADDRESS, POOL_PRICE_DECIMALS, INIT_POOL_BALANCE, INIT_USER_POOL_BALANCE


ZERO_BYTES32 = "0x0000000000000000000000000000000000000000000000000000000000000000"

# TODO Ask ChatGPT to generate test cases in vyper
# (done) depositing in pool increases total_assets
# (done) max liquid == total assetes - deployed - locked profits
# (done) max flash loan == max liquid
# owner never gets collector fees on collect_interest, reduce_credit, impair, or divest_vault

# 4626 Vault Invest/Divest

# (done) owner priviliges on investment functions
# vault_investment goes up by _amount 
# only vault that gets deposited into has vault_investment changed
# emits InvestVault event X params
# emits RevenueGenereated event with X params and FEE_TYPES.DEPOSIT
# investing in vault increased total_deployed by _amount
# investing in vault increases vault.balanceOf(pool) by shares returned in vault.deposit
# investing in vault increases vault.balanceOf(pool) by expected shares using _amount and pre-deposit share price
# 
# divesting vault decreases total_deployed
# divesting vault 
# emits DivestVault event with X params
# emits RevenueGenereated event with X params and FEE_TYPES.WITHDRAW
# divesting vault decreases vault.balanceOf(pool)
# divesting vault decreases vault.balanceOf(pool) by shares returned in vault.withdraw
# divesting vault decreases vault.balanceOf(pool) by expected shares using _amount and pre-withdraw share price

# (done) fee updates in state
# (done) fee update emits SetXFee event with X params and FEE_TYPES.Y
# (done) fee updates affect deposit/withdraw pricing
# (done) fees emitted properly in RevenueGenerated


def test_assert_pool_constants(pool):
    """
    Test hardcoded constants in contract are what they're supposed to be
    """
    assert pool.FEE_COEFFICIENT() == 10000  # 100% in bps
    assert pool.SNITCH_FEE() == 500        # 5% in bps
    # @notice 5% in bps. Max fee that can be charged for non-performance fee
    assert pool.PRICE_DECIMALS() == POOL_PRICE_DECIMALS
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
    assert pool.min_deposit() == 1
    assert pool.total_deployed() == 0
    assert pool.asset() == base_asset.address
    # ensure ownership and revenue is initialized properly
    assert pool.owner() == admin
    assert pool.pending_owner() == ZERO_ADDRESS
    assert pool.rev_recipient() == admin
    assert pool.pending_rev_recipient() == ZERO_ADDRESS
    assert pool.max_assets() == MAX_UINT
    # ensure profit logic is initialized properly
    assert pool.locked_profits() == 0
    assert pool.vesting_rate()== 317891 # default eek
    assert pool.last_report() == pool.eval('block.timestamp')
    # ensure vault logic is initialized properly
    assert pool.totalSupply() == 0
    assert pool.totalAssets()== 0


############################################
########                            ########
########  Basic Asset Functionality ########
########                            ########
############################################

@pytest.mark.pool
def test_depositing_in_pool_increases_total_assets(pool, admin, me, base_asset, init_token_balances):
    assert base_asset.balanceOf(pool) == init_token_balances * 2
    assert pool.totalAssets() == init_token_balances * 2

    base_asset.mint(me, 100)
    base_asset.approve(pool, 100, sender=me)
    pool.deposit(100, me, sender=me)
    assert base_asset.balanceOf(pool) == 100 + init_token_balances * 2
    assert pool.totalAssets() == 100 + init_token_balances * 2

    base_asset.mint(me, 100)
    base_asset.approve(pool, 100, sender=me)
    pool.mint(100, me, sender=me)
    assert base_asset.balanceOf(pool) == 200 + init_token_balances * 2
    assert pool.totalAssets() == 200 + init_token_balances * 2
    

@pytest.mark.pool
def test_withdrawing_from_pool_decreases_total_assets(pool, admin, me, base_asset, init_token_balances):
    assert base_asset.balanceOf(pool) == init_token_balances * 2
    assert pool.totalAssets() == init_token_balances * 2

    pool.withdraw(100, me, me, sender=me)
    assert base_asset.balanceOf(pool) == init_token_balances * 2 - 100
    assert pool.totalAssets() == init_token_balances * 2 - 100
    
    base_asset.mint(me, 100)
    base_asset.approve(pool, 100, sender=me)
    pool.redeem(100, me, me, sender=me)
    assert base_asset.balanceOf(pool) == init_token_balances * 2 - 200
    assert pool.totalAssets() == init_token_balances * 2 - 200


@pytest.mark.pool
def test_depositing_in_pool_increases_total_supply(pool, admin, me, base_asset, init_token_balances):
    assert pool.total_supply() == init_token_balances * 2

    base_asset.mint(me, 100)
    base_asset.approve(pool, 100, sender=me)
    pool.deposit(100, me, sender=me)
    assert pool.total_supply() == 100 + init_token_balances * 2

    base_asset.mint(me, 100)
    base_asset.approve(pool, 100, sender=me)
    pool.mint(100, me, sender=me)
    assert pool.total_supply() == 200 + init_token_balances * 2
    

@pytest.mark.pool
def test_withdrawing_from_pool_decreases_total_supply(pool, admin, me, base_asset, init_token_balances):
    assert pool.total_supply() == init_token_balances * 2

    pool.withdraw(100, me, me, sender=me)
    assert pool.total_supply() == init_token_balances * 2 - 100
    
    base_asset.mint(me, 100)
    base_asset.approve(pool, 100, sender=me)
    pool.redeem(100, me, me, sender=me)
    assert pool.total_supply() == init_token_balances * 2 - 200
    

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
@given(amount=st.integers(min_value=POOL_PRICE_DECIMALS, max_value=INIT_USER_POOL_BALANCE),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_fuzz_set_max_assets_amount(pool, base_asset, admin, me, amount, init_token_balances):
    assert pool.max_assets() == MAX_UINT
    pool.set_max_assets(amount, sender=admin)
    assert pool.max_assets() == amount

    current_assets = pool.totalAssets() 
    assert current_assets == init_token_balances * 2 # ensure clean state
    base_asset.mint(me, amount + 1, sender=me) # do + 1 to test max overflow
    base_asset.approve(pool, amount + 1, sender=me)
    if current_assets > amount:
        with boa.reverts():
            pool.deposit(amount, me, sender=me) # up to limit should work
    else:
        pool.deposit(amount, me, sender=me) # up to limit should work
        with boa.reverts():
            pool.deposit(1, me, sender=me) # 1 over limit

@pytest.mark.pool
@pytest.mark.pool_owner
def test_set_min_deposit_below_1_is_invalid(pool, admin, me):
    with boa.reverts():
        pool.set_min_deposit(0, sender=admin)
    with boa.reverts():
        pool.set_min_deposit(0, sender=me)

    pool.set_min_deposit(1, sender=admin)
    assert pool.min_deposit() == 1

@pytest.mark.pool
@pytest.mark.pool_owner
def test_set_min_deposit_only_owner(pool, admin, me):
    assert pool.min_deposit() == 1
    pool.set_min_deposit(MAX_UINT, sender=admin)
    assert pool.min_deposit() == MAX_UINT
    
    pool.set_min_deposit(100, sender=admin)
    assert pool.min_deposit() == 100
    
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
@given(amount=st.integers(min_value=POOL_PRICE_DECIMALS, max_value=INIT_USER_POOL_BALANCE),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_fuzz_set_min_deposit_amount(pool, base_asset, admin, me, init_token_balances, amount):
    assert pool.min_deposit() == 1
    pool.set_min_deposit(amount, sender=admin)
    assert pool.min_deposit() == amount

    assert pool.totalAssets() == init_token_balances * 2 # ensure clean state
    base_asset.mint(me, amount, sender=me) # do + 1 to test max overflow
    base_asset.approve(pool, amount, sender=me)

    with boa.reverts():
        pool.deposit(amount - 1, me, sender=me) # under min fails

    pool.deposit(amount, me, sender=me) # up to limit should work

    base_asset.mint(me, amount * 2, sender=me)
    base_asset.approve(pool, amount * 2, sender=me)
    pool.deposit(amount * 2, me, sender=me) # over limit should work


@pytest.mark.pool
@pytest.mark.pool_owner
def test_only_owner_can_set_vesting_rate(pool, admin, me):
    assert pool.vesting_rate() == 317891
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
@given(amount=st.integers(min_value=POOL_PRICE_DECIMALS, max_value=10**18),) # max = DEGRADATAION_COEFFECIENT
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_fuzz_set_vesting_rate_amount(pool, base_asset, admin, me, amount):
    assert pool.vesting_rate() == 317891

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
@given(pittance_fee=st.integers(min_value=1, max_value=MAX_PITTANCE_FEE),
        perf_fee=st.integers(min_value=1, max_value=FEE_COEFFICIENT),
        amount=st.integers(min_value=POOL_PRICE_DECIMALS, max_value=10**25),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_revenue_calculations_based_on_fees_state(
    pool, pool_fee_types, admin, me, base_asset, flash_borrower,
    pittance_fee, perf_fee, amount,
    _gen_rev, _collect_interest,
):
    null_fees = dict(zip(pool_fee_types, (0,)*len(pool_fee_types)))
    for fee_type in pool_fee_types:
         # reset all fees so they dont pollute test. have separete test for composite fees
        pool.eval(SET_FEES_TO_ZERO)
        pool.eval("self.accrued_fees = 0")

        set_fee = getattr(pool, f'set_{fee_type}_fee', lambda x: "Fee type does not exist in Pool.vy")
        fee_bps = pittance_fee if _is_pittance_fee(fee_type) else perf_fee

        set_fee(fee_bps, sender=admin) # set fee so we generate revenue
        assert fee_bps == pool.eval(f'self.fees.{fee_type}')
        print(f"\n\n\n")
        rev_data = _gen_rev(fee_type, amount)

        pittance_fee_rev = math.floor((amount * fee_bps) / FEE_COEFFICIENT)
        
        # TODO TEST figure out why pool returns inconsistent events btw calls. probably boa thing
        # assert rev_data['event'] is not None
        # TODO TEST THIS BLOCK NEVER GETS HIT

        if rev_data['event'] == None:
            print(f"NO EVENT FOR FEE {fee_type}/{rev_data}")
            assert False

        event = rev_data['event']
        print(f"REPORT FEE - {fee_type} - {event['fee_type']}")
        match fee_type:
            case 'performance':
                assert event['fee_type'] == 1
                assert to_checksum_address(event['token']) == pool.address
                assert event['amount'] == rev_data['interest']
                assert event['revenue'] == math.floor((rev_data['interest'] * fee_bps) / FEE_COEFFICIENT)
                assert to_checksum_address(event['payer']) == pool.address
                assert to_checksum_address(event['receiver']) == admin
            case 'deposit':
                assert event['fee_type'] == 2
                assert to_checksum_address(event['token']) == pool.address
                assert event['amount'] == amount
                assert event['revenue'] == pittance_fee_rev
                assert to_checksum_address(event['payer']) == pool.address
                assert to_checksum_address(event['receiver']) == admin
            case 'withdraw':
                assert event['fee_type'] == 4
                assert to_checksum_address(event['token']) == pool.address
                assert event['amount'] == amount
                assert event['revenue'] == pittance_fee_rev
                assert to_checksum_address(event['payer']) == me
                assert to_checksum_address(event['receiver']) == pool.address
            case 'flash':
                assert event['fee_type'] == 8
                assert to_checksum_address(event['token']) == base_asset.address
                assert event['amount'] == amount
                assert event['revenue'] == pittance_fee_rev
                assert to_checksum_address(event['payer']) == flash_borrower.address
                assert to_checksum_address(event['receiver']) == pool.address
            case 'collector':
                assert event['fee_type'] == 16
                assert to_checksum_address(event['token']) == base_asset.address
                assert event['amount'] == amount
                assert event['revenue'] == pittance_fee_rev
                assert to_checksum_address(event['payer']) == pool.address
                assert to_checksum_address(event['receiver']) == flash_borrower.address
            case 'referral':
                assert event['fee_type'] == 32
                assert to_checksum_address(event['token']) == pool.address
                assert event['amount'] == amount
                assert event['revenue'] == pittance_fee_rev
                assert to_checksum_address(event['payer']) == pool.address
                assert to_checksum_address(event['receiver']) == flash_borrower.address # random referrer for testing
                
                if amount > INTEREST_TIMESPAN_SEC:
                    assert False
            # TODO TEST other fee types

        
@pytest.mark.pool
@pytest.mark.rev_generator
@given(pittance_fee=st.integers(min_value=1, max_value=MAX_PITTANCE_FEE),
        perf_fee=st.integers(min_value=1, max_value=FEE_COEFFICIENT),
        amount=st.integers(min_value=POOL_PRICE_DECIMALS, max_value=10**25),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_revenue_calculations_with_multiple_fees(
    pool, pool_fee_types, admin, me, base_asset,
    pittance_fee, perf_fee, amount
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
    logs = pool.get_logs()
    deposit_rev_event = _find_event_by({ 'fee_type': 2 }, logs)
    referral_rev_event = _find_event_by({ 'fee_type': 32 }, logs)
    assert deposit_rev_event['fee_type'] == 2
    assert to_checksum_address(deposit_rev_event['receiver']) == admin
    assert to_checksum_address(deposit_rev_event['payer']) == pool.address
    assert referral_rev_event['fee_type'] == 16
    assert to_checksum_address(referral_rev_event['receiver']) == ZERO_ADDRESS
    assert to_checksum_address(referral_rev_event['payer']) == pool.address

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
@given(amount=st.integers(min_value=POOL_PRICE_DECIMALS, max_value=10**25),
        pittance_fee=st.integers(min_value=1, max_value=MAX_PITTANCE_FEE)) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_pittance_fees_emit_revenue_generated_event(
    pool, pittance_fee_types, admin, me, base_asset,
    pittance_fee, amount,
    _deposit
):
    total_accrued_fees = 0  # var accumulate fees across txs in loop
    for idx, fee_name in enumerate(pittance_fee_types):
        assert total_accrued_fees == pool.accrued_fees()

        fee_enum_idx = idx + 1
        fee_type_uint = 2**fee_enum_idx
        set_fee = getattr(pool, f'set_{fee_name}_fee', lambda x: "Fee type does not exist in Pool.vy")

        expected_rev = math.floor(((amount * pittance_fee) / FEE_COEFFICIENT))
        
        set_fee(pittance_fee, sender=admin) # set fee so we generate revenue

        # TODO dynamic fee generating HuF
        _deposit(amount, me)

        
        # test deposit event before other pool state
        events = pool.get_logs()

        # Have multiple RevGenerated events based on function called.
        # deposit() emits DEPOSIT + REFERRAL, collect_interest() emits PERFORMANCE + COLLECTOR
        # they have predetermined ordering and are always called in same order
        event = None

        match fee_name:
            case 'deposit':
                event = _find_event_by({ 'fee_type': 2 }, events)
                assert event is not None
                assert to_checksum_address(event['payer']) == pool.address
                assert to_checksum_address(event['token']) == pool.address
                assert to_checksum_address(event['receiver']) == admin
            case 'withdraw':
                event = _find_event_by({ 'fee_type': 4 }, events)
                assert event is not None
                assert to_checksum_address(event['payer']) == me
                assert to_checksum_address(event['token']) == pool.address
                assert to_checksum_address(event['receiver']) == admin
            case 'flash':
                event = _find_event_by({ 'fee_type': 8 }, events)
                assert event is not None
                assert to_checksum_address(event['payer']) == pool.address
                assert to_checksum_address(event['token']) == base_asset.address
                assert to_checksum_address(event['receiver']) == me
            case 'collector':
                event = _find_event_by({ 'fee_type': 16 }, events)
                assert event is not None
                assert to_checksum_address(event['payer']) == pool.address
                assert to_checksum_address(event['token']) == base_asset.address
                assert to_checksum_address(event['receiver']) == me
            case 'referral':
                event = _find_event_by({ 'fee_type': 32 }, events)
                assert event is not None
                assert to_checksum_address(event['payer']) == pool.address
                assert to_checksum_address(event['token']) == pool.address
                assert to_checksum_address(event['receiver']) == me
            case 'snitch':
                event = _find_event_by({ 'fee_type': 64 }, events)
                assert to_checksum_address(event['payer']) == pool.address
                assert to_checksum_address(event['token']) == base_asset.address
                assert to_checksum_address(event['receiver']) == me

        # print("find rev eevent", event.event_type.name, rev_event_type, rev_event_type == event.event_type.name, rev_event_type in e_types, fee_type)
        assert event['amount'] == amount
        assert event['revenue'] == expected_rev

        # check post deposit state after event so boa doesnt overwrite
        total_accrued_fees += expected_rev
        assert pool.accrued_fees() == total_accrued_fees

@pytest.mark.pool
@pytest.mark.rev_generator
@given(pittance_fee=st.integers(min_value=MAX_PITTANCE_FEE + 1, max_value=65535)) #max = uint16
def test_cant_set_pittance_fee_over_200_bps(pool, pittance_fee_types, admin, pittance_fee):
    for fee_type in pittance_fee_types:
        set_fee = getattr(pool, f'set_{fee_type}_fee', lambda x: "Fee type does not exist in Pool.vy")
        with boa.reverts():
            set_fee(pittance_fee, sender=admin)

@pytest.mark.pool
@pytest.mark.rev_generator
@given(pittance_fee=st.integers(min_value=1, max_value=MAX_PITTANCE_FEE)) # min_val = 1 so no off by one when adjusting values
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
# @pytest.mark.event_emissions
# @given(fee_bps=st.integers(min_value=POOL_PRICE_DECIMALS, max_value=MAX_PITTANCE_FEE))
# @settings(max_examples=100, deadline=timedelta(seconds=1000))
# def test_cant_set_snitch_fee(pool, pool_fee_types, admin, fee_bps):
#     with boa.reverts(): # should revert bc changing constant
#     TODO figure out how to expect boa error not a tx revert for accessing constant
#         pool.eval('SNITCH_FEE = 0')

@pytest.mark.pool
@pytest.mark.rev_generator
@pytest.mark.event_emissions
@given(fee_bps=st.integers(min_value=1, max_value=MAX_PITTANCE_FEE))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_setting_fees_emits_standard_event(pool, pool_fee_types, admin, fee_bps):
    for idx, fee_type in enumerate(pool_fee_types):
        set_fee = getattr(pool, f'set_{fee_type}_fee', lambda x: "Fee type does not exist in Pool.vy")
        set_fee(fee_bps, sender=admin)

        enum_idx = 2**idx  # boa enums are exponential
        event = _find_event_by({ 'fee_type': enum_idx}, pool.get_logs())

        assert event['fee_bps'] == fee_bps
        assert event['fee_type'] == enum_idx
        assert pool.fees()[idx] == fee_bps

def _is_pittance_fee(fee_name: str) -> bool:
    if fee_name:
        match fee_name:
            case 'performance':
                return False
            case 'snitch':
                return False
            case _:
                return True


@pytest.mark.slow
@pytest.mark.pool
@pytest.mark.invariant
@given(deployed=st.integers(min_value=POOL_PRICE_DECIMALS, max_value=INIT_POOL_BALANCE),
        locked=st.integers(min_value=POOL_PRICE_DECIMALS, max_value=INIT_POOL_BALANCE),)
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_invariant_max_liquid_is_total_less_deployed_and_locked(pool, base_asset, deployed, locked):    
    def test_invariant():
        total = pool.totalAssets()
        deployed = pool.total_deployed()
        locked = pool.locked_profits()
    
        liquid = total - deployed - locked

        # TODO TEST should this be its own "test_invariant_liquid_assets_are"
        if deployed == 0 and locked == 0:
            assert liquid == total
        elif deployed == 0 and locked > 0:
            assert liquid == total - locked
        elif locked == 0 and deployed > 0:
            assert liquid == total - deployed

    # initial test
    test_invariant()
    total = pool.totalAssets()
    deployable = deployed if pool.totalAssets() > deployed else total
    # remove liquid assets from pool
    pool.eval(f"self.total_deployed = {deployable}")
    test_invariant()
    # add extra deposits to pool for more liquid assets
    pool.eval(f"self.total_assets += {deployed}")
    test_invariant()
    # add locked profit, should increase total_assetes to not fuckup accounting for whatever reason
    pool.eval(f"self.total_assets = {locked}")    
    pool.eval(f"self.locked_profits = {locked}")    
    test_invariant()
    # moar liquid funds
    pool.eval(f"self.total_deployed = {0}")
    test_invariant()
    # drain the pool entirely
    pool.eval(f"self.total_assets = {0}")    
    pool.eval(f"self.locked_profits = {0}")    
    test_invariant()


@pytest.mark.slow
@pytest.mark.pool
@pytest.mark.invariant
@given(deployed=st.integers(min_value=POOL_PRICE_DECIMALS, max_value=INIT_POOL_BALANCE),
        locked=st.integers(min_value=POOL_PRICE_DECIMALS, max_value=INIT_POOL_BALANCE),)
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_invariant_max_flash_loan_is_max_liquid(pool, base_asset, deployed, locked):    
    def test_invariant():
        total = pool.totalAssets()
        deployed = pool.total_deployed()
        locked = pool.locked_profits()
    
        liquid = total - deployed - locked

        assert pool.maxFlashLoan(base_asset) == liquid
    
    # initial test
    test_invariant()
    total = pool.totalAssets()
    deployable = deployed if pool.totalAssets() > deployed else total
    # remove liquid assets from pool
    pool.eval(f"self.total_deployed = {deployable}")
    test_invariant()
    # add extra deposits to pool for more liquid assets
    pool.eval(f"self.total_assets += {deployed}")
    test_invariant()
    # add locked profit, should increase total_assetes to not fuckup accounting for whatever reason
    pool.eval(f"self.total_assets = {locked}")    
    pool.eval(f"self.locked_profits = {locked}")    
    test_invariant()
    # moar liquid funds
    pool.eval(f"self.total_deployed = {0}")
    test_invariant()
    # drain the pool entirely
    pool.eval(f"self.total_assets = {0}")    
    pool.eval(f"self.locked_profits = {0}")    
    test_invariant()

@pytest.mark.slow
@pytest.mark.ERC4626
@given(shares=st.integers(min_value=POOL_PRICE_DECIMALS, max_value=10**25 / 2),
       assets=st.integers(min_value=POOL_PRICE_DECIMALS, max_value=10**25,))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_invariant_min_deposit_at_least_1(pool, base_asset, me, admin, shares, assets):
    pool.min_deposit() == 1
    with boa.reverts():
        pool.set_min_deposit(0, sender=admin)

    pool.set_min_deposit(100, sender=admin)
    pool.min_deposit() == 100

    pool.set_min_deposit(1, sender=admin)
    pool.min_deposit() == 1

    pool.set_min_deposit(MAX_UINT, sender=admin)
    pool.min_deposit() == MAX_UINT

    with boa.reverts():
        pool.set_min_deposit(0, sender=admin)


@pytest.mark.slow
@pytest.mark.ERC4626
@given(shares=st.integers(min_value=POOL_PRICE_DECIMALS, max_value=10**25 / 2),
       assets=st.integers(min_value=POOL_PRICE_DECIMALS, max_value=10**25,))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_invariant_preview_incorporates_fees_into_share_price(pool, base_asset, me, admin, shares, assets):
    pool.eval(SET_FEES_TO_ZERO)
    pool.eval(f"self.accrued_fees = 0")
    pool.eval(f"self.total_assets = {assets}")
    pool.eval(f"self.total_supply = {shares}")
    pool.eval(f"self.balances[{me}] = {shares}")

    assets_w_decimals = assets * POOL_PRICE_DECIMALS
    shares_w_decimals = shares / POOL_PRICE_DECIMALS
    redeemable = pool.previewRedeem(shares)
    withdrawable = pool.previewWithdraw(assets)

    print(f"")
    print(f"pool asset/shares {assets}/{shares}/ redeem/withdraw {redeemable}/{withdrawable}")
    print(f"pool pricing - {pool.vault_assets()}/{pool.totalSupply()}|/{pool.price()}")

    expected_price = (assets * POOL_PRICE_DECIMALS) / shares
    expected_redeemable = math.floor((shares * expected_price) / POOL_PRICE_DECIMALS)
    assert redeemable == expected_redeemable
    assert withdrawable == shares

    pool.set_withdraw_fee(100, sender=admin)

    redeemable_w_fee = pool.previewRedeem(shares, sender=me)
    withdrawable_w_fee = pool.previewWithdraw(assets, sender=me)

    # TODO TEST fix withdraw fees
    assert redeemable_w_fee < assets and redeemable_w_fee > 0
    assert withdrawable_w_fee < shares and withdrawable_w_fee > 0
    assert redeemable_w_fee == expected_redeemable
    assert withdrawable_w_fee == shares

    expected_mintable = math.floor((shares * expected_price) / POOL_PRICE_DECIMALS)
    expected_depositable = math.floor((assets * POOL_PRICE_DECIMALS) / expected_price)
    mintable = pool.previewMint(shares)
    depositable = pool.previewDeposit(assets)
    assert mintable == expected_mintable
    assert depositable == expected_depositable

    pool.set_deposit_fee(100, sender=admin)

    mintable_w_fee = pool.previewMint(shares, sender=me)
    depositable_w_fee = pool.previewDeposit(assets, sender=me)
    # same assets bc fee is taken in minflation post deposit/mint
    assert mintable_w_fee == expected_mintable
    assert depositable_w_fee == expected_depositable
    
    if assets > 0:
        pool.eval(f"self.total_deployed = {assets - 1}")
        redeemable = pool.previewRedeem(shares)
        withdrawable = pool.previewWithdraw(assets)
        
        assert redeemable == 1
        assert withdrawable == 0



# @pytest.mark.ERC4626
# @given(amount=st.integers(min_value=0, max_value=(MAX_UINT / 4) * 3),)
# @settings(max_examples=100, deadline=timedelta(seconds=1000))
# def test_cant_withdraw_more_than_liquid(pool, base_asset, me, admin, init_token_balances, amount):

