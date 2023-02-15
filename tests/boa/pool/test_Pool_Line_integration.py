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

ONE_YEAR_IN_SEC=60*60*24*365.25
BYTES32_STRING = 0x0000000000000000000000000000000000000000000000000000000000000000
INTEREST_RATE_COEFFICIENT = 315576000000
INTEREST_TIMESPAN_SEC = int(ONE_YEAR_IN_SEC / 24)

# Debt DAO Ponzinomics Test

# 1. pool MUST borrow from line where they are borrower
# ??y/n?? pool MUST NOT be able to post collateral to loans
# 1. 
# 1. cannot borrow from a position that isnt denominated in pool ASSET
# 1. Pool MUST repay all debt if total_assets are available and they are in  DEFUALT/INSOLVENT status
# 1. anyone can call emergency_repay to repay debt on defaulted lines
# 1. emergency_repay MUST NOT work on ACTIVE lines
# 1. emergency_repay MUST slash accrued_fees and pool assets if successful
# 1. Pool MUST be able to open multiple positions per line. 
# 1. Pool MUST be able to own multiple lines. 
# 1. Pool can only borrow from one lender per line. Line constraint bc can only borrow ASSET, lender can only create one position per line.
# 1. MUST be able to track initial principal drawn vs repaid
# 1. MUST be able to track initial interest owed on a line


# 1. Can impair on a position with 0 debt
# 1. Impairing position with 0 debt MUST NOT reduce locked_profit, total_assets, or accrued_fees
# 1. Impairing position with 0 debt MUST be successful if a non-0 debt call would succeed
# 1. 


# 1. MUST NOT repay debt to line where pool isnt borrower
# 1. Pool shareholders MUST NOT redeem debt assets, only users deposits
# 1. MUST be able to use debt assets to invest into LoC 
# 1. MUST be able to use debt assets to invest into vaults
# 1. 

# 1. can make a Spigot rev_recipient
# 1. can make a Spigot owner
# 1. Spigot rev_recipient can claim_rev via claimRevenue
# 1. Spigot can whitelist() Pool owner funcs
# 1. Spigot can operate() Pool owner funcs

# 1. 
# 1. can addCollateral to line escrow
# 1. can only addCollateral from liquid total_assets
# 1. addCollateral increases self.total_deployed
# 1. addCollateral reduces self.total_assets




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
def test_pool_can_deposit_to_line(
    pool, mock_line, admin, me, base_asset,
     _add_credit, _get_position, init_token_balances,
     amount
):
    start_balance = init_token_balances * 2
    id = _add_credit(amount)

    assert base_asset.balances(pool) == start_balance
    assert base_asset.balances(mock_line) == amount

    position = _get_position(id)

    assert position['lender'] == pool.address
    assert position['deposit'] == amount
    assert position['token'] == base_asset.address
    assert base_asset.balances(pool) == start_balance
    assert base_asset.balances(mock_line) == amount


@pytest.mark.pool
@pytest.mark.line_integration
@given(amount=st.integers(min_value=1, max_value=10**25),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_pool_can_increase_deposit_to_line(
    pool, mock_line, admin, me, base_asset,
    _deposit, _add_credit, _get_position, init_token_balances,
    amount
):
    start_balance = init_token_balances * 2
    _deposit(amount * 2, me)
    id = _add_credit(amount, new_deposit=False)
    position = _get_position(id)

    assert position['lender'] == pool.address
    assert position['deposit'] == amount
    assert position['token'] == base_asset.address
    assert base_asset.balances(pool) == start_balance + amount
    assert base_asset.balances(mock_line) == amount

    pool.increase_credit(mock_line, id, amount, sender=admin)

    position2 = _get_position(id)

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
    position = _get_position(id)

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

@pytest.mark.pool
@pytest.mark.line_integration
@given(amount=st.integers(min_value=1, max_value=10**25),) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_pool_can_change_rates_on_nonexistant_position(pool, mock_line, admin, me, base_asset, amount):
    with boa.reverts(): # error from line contract gets bubbled to Pool
        assert False
        # TODO TEST cant pas in bytes32 directly to function
        # pool.set_rates(mock_line, BYTES32_STRING, 1_000, 100, sender=admin)


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
    amount
):
    facility_fee = 1000 # 10%
    id = _add_credit(amount, 0, facility_fee)
    p = _get_position(id)

    assert p['deposit'] == amount

    boa.env.time_travel(seconds=INTEREST_TIMESPAN_SEC)
    mock_line.accrueInterest(id)
    expected_interest = math.floor((p['deposit'] * facility_fee * INTEREST_TIMESPAN_SEC) / INTEREST_RATE_COEFFICIENT)
    
    p2 = _get_position(id)
    assert pool.total_assets() == amount # ensure original accounting balance
    assert p2['interestAccrued'] == expected_interest
    _repay(id, expected_interest)

    collected =  pool.collect_interest(mock_line, id)
    assert collected == expected_interest
    assert pool.total_assets() == amount + expected_interest
    assert pool.locked_profits() == expected_interest # no matter the vesting_rate MUST have 100% at block of collection

    ### TODO TEST reduce_credit and impair function similarly



@pytest.mark.pool
@pytest.mark.line_integration
def test_anyone_can_call_collect_interest(
    pool, mock_line, admin, me, base_asset,
    _add_credit, _get_position, _repay,
):
    amount = 10_000*10**18
    facility_fee = 1000 # 10%
    
    id = _add_credit(amount, 0, facility_fee)
    p = _get_position(id)
    assert p['deposit'] == amount

    # print("time before travel", boa.env.get_block)

    boa.env.time_travel(seconds=INTEREST_TIMESPAN_SEC)
    
    (drate, frate, last_accrued) = mock_line.rates(id)
    print(f"deposit == {p['principal']}/{p['deposit']}, d/frate = {last_accrued}/{frate}")
    mock_line.accrueInterest(id)
    interest_events = mock_line.get_logs()
    print("interest events", interest_events)
    # without math.floow this has extra 1e19 for some reason
    expected_interest = math.floor((p['deposit'] * facility_fee * INTEREST_TIMESPAN_SEC) / INTEREST_RATE_COEFFICIENT)

    p2 = _get_position(id)
    assert p2['interestRepaid'] == 0
    assert p2['interestAccrued'] == expected_interest

    print(f"expected interest == {expected_interest}, accrued = {p['interestAccrued']}")
    
    _repay(id, expected_interest)
    
    p3 = _get_position(id)
    assert p3['interestRepaid'] == expected_interest
    assert p3['interestAccrued'] == 0

    assert pool.locked_profits() == 0
    pool.collect_interest(sender=me)
    assert pool.locked_profits() == amount
    
    p4 = _get_position(id)
    assert p4['interestRepaid'] == 0 
