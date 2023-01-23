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

MAX_UINT = 115792089237316195423570985008687907853269984665640564039457584007913129639935
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
ClaimRevenueEventLogIndex = 2 # log index of ClaimRevenue event inside claim_rev logs (approve, transfer, claim, price)
MAX_PITANCE_FEE = 200 # 2% in bps
FEE_COEFFICIENT = 10000 # 100% in bps


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

# 1. fee updates in state
# 1. fee update emits SetXFee event with X params and FEE_TYPES.Y
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
    assert pool.DEGRADATION_COEFFICIENT() == 1e18

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
    assert pool.locked_profit() == 0
    assert pool.vesting_rate()== 46000000000000 # default eek
    assert pool.last_report() == pool.eval('block.timestamp')
    # ensure vault logic is initialized properly
    assert pool.totalSupply() == 0
    assert pool.total_assets()== 0



@pytest.mark.pool
@pytest.mark.rev_generator
@given(amount=st.integers(min_value=1, max_value=MAX_UINT),
        pittance_fee=st.integers(min_value=1, max_value=MAX_PITANCE_FEE)) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_emit_revenue_generated_event(pool, pool_fee_types, admin, me, base_asset, pittance_fee, amount):
    fee_types =  [(idx, fee, pittance_fee) for idx, fee in enumerate(pool_fee_types)][1:] # remove performance fees from test
    for fee_type in fee_types:
        fee_enum_idx = fee_type[0] + 1 # offset for removed performance fee
        fee_name = fee_type[1]
        set_fee = getattr(pool, f'set_{fee_name}_fee', lambda x: "Fee type does not exist in Pool.vy")

        set_fee(pittance_fee, sender=admin)
        event = pool.get_logs()[0]
        assert f'{event.event_type}' == f'event FeeSet(uint16,FEE_TYPES)'
        print("set fees", event.args_map['fee_bps'], event.args_map['fee_type'], pool.fees(), f'set_{fee_name}_fee')
        assert event.args_map['fee_bps'] == str(pittance_fee)
        assert event.args_map['fee_type'] == str(fee_enum_idx)
        assert pool.fees()[-fee_enum_idx] == pittance_fee

        base_asset.mint(me, amount)
        base_asset.approve(pool, amount, sender=me)
        assert base_asset.balanceOf(me)

        expected_rev = math.floor(((amount * pittance_fee) / FEE_COEFFICIENT))
        shares = pool.deposit(amount, me, sender=me) # TODO need to map function to fee type
        # event = pool.get_logs()[0]
        # assert f'{event.event_type}' == 'event RevenueGenerated(address,address,uint256,uint256,FEE_TYPES,address)'
        # assert event.args_map['amount'] == amount
        # assert event.args_map['revenue'] == expected_rev
        # assert event.args_map['fee_type'] == fee_type
        # assert to_checksum_address(event.args_map['payer']) == me # TODO change based on type
        # assert to_checksum_address(event.args_map['token']) == base_asset # TODO change based on type
        # assert to_checksum_address(event.args_map['receiver']) == admin# TODO change based on type
        assert pool.accrued_fees() == expected_rev


@pytest.mark.pool
@pytest.mark.rev_generator
@given(amount=st.integers(min_value=1, max_value=MAX_UINT),
        pittance_fee=st.integers(min_value=1, max_value=MAX_PITANCE_FEE)) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_cant_set_pittance_fee_over_200_bps(pool, pool_fee_types, admin, me, base_asset, pittance_fee, amount):
    pittance_types = pool_fee_types[1:] # remove performance fees from test
    for fee_type in pittance_types:
        set_fee = getattr(pool, f'set_{fee_type}_fee', lambda x: "Fee type does not exist in Pool.vy")
        with boa.reverts():
            set_fee(MAX_PITANCE_FEE + 1, sender=admin)

@pytest.mark.pool
@pytest.mark.rev_generator
@given(amount=st.integers(min_value=1, max_value=MAX_UINT),
        pittance_fee=st.integers(min_value=1, max_value=MAX_PITANCE_FEE)) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_cant_set_performance_fee_over_10000_bps(pool, pool_fee_types, admin, me, base_asset, pittance_fee, amount):
    with boa.reverts():
        pool.set_performance_fee(MAX_PITANCE_FEE + 1, sender=admin)

    # deposit, withdraw, flash should all be easy
    
    # print("generate rev event", response)

    # SNITCH cant have 0 amount rev