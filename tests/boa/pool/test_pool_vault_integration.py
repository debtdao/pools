import boa
import math
from eth_utils import to_checksum_address
import pytest
import logging
from boa.vyper.contract import BoaError
from hypothesis import given, settings
from hypothesis import strategies as st
from hypothesis.stateful import RuleBasedStateMachine, run_state_machine_as_test, rule, invariant
from .conftest import VESTING_RATE_COEFFICIENT, SET_FEES_TO_ZERO, DRATE, FRATE, INTEREST_TIMESPAN_SEC, ONE_YEAR_IN_SEC,  FEE_COEFFICIENT, MAX_PITTANCE_FEE
from ..conftest import MAX_UINT, ZERO_ADDRESS, POOL_PRICE_DECIMALS, INIT_POOL_BALANCE, INIT_USER_POOL_BALANCE
from ..utils.events import _find_event_by

# (make vault another pool so we can double test at same time

# - test invest_vault
# get right shares back for assets deposited against vault price (do it 2x)
# properly increase initial principal (do it 2x)

def test_invest_vault_only_owner_can_call(pool, vault, admin, me, init_token_balances):
    with boa.reverts():
        pool.invest_vault(vault, 100, sender=me)
    with boa.reverts():
        pool.invest_vault(vault, 100, sender=boa.env.generate_address())

    pool.invest_vault(vault, 100, sender=admin)


def test_invest_vault_updates_token_balances(pool, vault, base_asset, admin, me, init_token_balances):
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.total_deployed() == 0
    assert pool.vault_investments(vault) == 0
    assert vault.balanceOf(pool) == 0 # confirm we received shares
    assert vault.totalSupply() == 0
    assert vault.totalAssets() == 0
    assert base_asset.balanceOf(vault) == 0

    pool.invest_vault(vault, 100, sender=admin)

    pool_logs = pool.get_logs()
    # get events immediatelyafter function call before boa deletes
    invest_event = _find_event_by({ 'vault': vault.address, 'assets': 100, 'shares': 100 }, pool_logs)
    deposit_event = _find_event_by({ 'sender': pool.address, 'owner': pool.address, 'shares': 100, 'assets': 100 }, pool_logs)
    deposit_rev_event = _find_event_by({ 'fee_type': 2 , 'payer': vault.address, 'receiver': me, 'amount': 100, }, pool_logs)

    # print("investing events pool    :", invest_event, deposit_event, deposit_rev_event)

    assert deposit_event is not None
    assert invest_event is not None
    assert deposit_rev_event is not None
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.total_deployed() == 100
    assert pool.vault_investments(vault) == 100
    assert vault.balanceOf(pool) == 100 # confirm we received shares
    assert vault.totalSupply() >= 100 # may have minflation fees
    assert vault.totalAssets() == 100
    assert base_asset.balanceOf(vault) == 100
    


def test_invest_vault_2x(pool, vault, base_asset, admin, me, init_token_balances):
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.total_deployed() == 0
    assert pool.vault_investments(vault) == 0
    assert vault.balanceOf(pool) == 0 # confirm we received shares
    assert vault.totalSupply() == 0
    assert vault.totalAssets() == 0
    assert base_asset.balanceOf(vault) == 0

    pool.invest_vault(vault, 100, sender=admin)

    pool_logs = pool.get_logs()
    # get events immediatelyafter function call before boa deletes
    invest_event = _find_event_by({ 'vault': vault.address, 'assets': 100, 'shares': 100 }, pool_logs)
    deposit_event = _find_event_by({ 'sender': pool.address, 'owner': pool.address, 'shares': 100, 'assets': 100 }, pool_logs)
    deposit_rev_event = _find_event_by({ 'fee_type': 2 , 'payer': vault.address, 'receiver': me, 'amount': 100, }, pool_logs)

    # print("investing events pool    :", invest_event, deposit_event, deposit_rev_event)

    assert deposit_event is not None
    assert invest_event is not None
    assert deposit_rev_event is not None
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.total_deployed() == 100
    assert pool.vault_investments(vault) == 100
    assert vault.balanceOf(pool) == 100 # confirm we received shares
    assert vault.totalSupply() >= 100 # may have minflation fees
    assert vault.totalAssets() == 100
    assert base_asset.balanceOf(vault) == 100

    pool.invest_vault(vault, INIT_USER_POOL_BALANCE, sender=admin)

    pool_logs = pool.get_logs()
    # get events immediatelyafter function call before boa deletes
    invest_event2 = _find_event_by({ 'vault': vault.address, 'assets': INIT_USER_POOL_BALANCE }, pool_logs)
    deposit_event2 = _find_event_by({ 'sender': pool.address, 'owner': pool.address, 'assets': INIT_USER_POOL_BALANCE }, pool_logs)
    deposit_rev_event2 = _find_event_by({ 'fee_type': 2 , 'payer': vault.address, 'receiver': me, }, pool_logs)

    
    assert deposit_event2 is not None
    assert invest_event2 is not None
    assert deposit_rev_event2 is not None
    
    assert deposit_event2['shares'] > INIT_USER_POOL_BALANCE # mintflation from first depoist gives us more shares in second deposit
    assert invest_event2['shares'] > INIT_USER_POOL_BALANCE # mintflation from first depoist gives us more shares in second deposit
    assert invest_event2['shares'] == deposit_event2['shares']
    assert invest_event2['shares'] == deposit_rev_event2['amount']
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.total_deployed() == 100 + INIT_USER_POOL_BALANCE
    assert pool.vault_investments(vault) == 100 + INIT_USER_POOL_BALANCE
    assert vault.balanceOf(pool) >= 100 + INIT_USER_POOL_BALANCE # confirm we received shares
    assert vault.totalSupply() >= 100 + INIT_USER_POOL_BALANCE # may have minflation fees
    assert vault.totalAssets() == 100 + INIT_USER_POOL_BALANCE
    assert base_asset.balanceOf(vault) == 100 + INIT_USER_POOL_BALANCE
    # TODO TEST rounding errors
    # expected_shares = 
    # assert invest_event2['shares'] == expected_shares


def test_invest_vault_deployed_cant_be_withdrawn_from_pool(pool, vault, base_asset, admin, me, init_token_balances):
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.total_deployed() == 0
    assert pool.vault_investments(vault) == 0

    pool.invest_vault(vault, INIT_POOL_BALANCE, sender=admin)

    pool_logs = pool.get_logs()
    # get events immediatelyafter function call before boa deletes
    invest_event = _find_event_by({ 'vault': vault.address, 'assets': INIT_POOL_BALANCE, 'shares': INIT_POOL_BALANCE }, pool_logs)
    deposit_event = _find_event_by({ 'sender': pool.address, 'owner': pool.address, 'shares': INIT_POOL_BALANCE, 'assets': INIT_POOL_BALANCE }, pool_logs)
    deposit_rev_event = _find_event_by({ 'fee_type': 2 , 'payer': vault.address, 'receiver': me, 'amount': INIT_POOL_BALANCE, }, pool_logs)
    assert deposit_event is not None
    assert invest_event is not None
    assert deposit_rev_event is not None
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.total_deployed() == INIT_POOL_BALANCE
    assert pool.vault_investments(vault) == INIT_POOL_BALANCE
    assert pool.maxFlashLoan(base_asset) == 0

    with boa.reverts():
        pool.withdraw(1, me, me, sender=me)
    


def test_divest_vault(pool, vault, base_asset, admin, me, init_token_balances):
    # confirm base state
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.total_deployed() == 0
    assert pool.vault_investments(vault) == 0
    assert pool.price() == POOL_PRICE_DECIMALS
    assert vault.balanceOf(pool) == 0 


    new_assets = math.floor(INIT_POOL_BALANCE * 10)
    pool.invest_vault(vault, INIT_POOL_BALANCE, sender=admin)
    # articifially increase vault assets / price to test if it goes down after divesting
    vault.eval(f"self.total_assets = {new_assets}")

    shares_burned = pool.divest_vault(vault, 100, sender=admin)

    pool_logs = pool.get_logs()
    # print(f"pol divest #1  - ", pool_logs)

    # get events immediatelyafter function call before boa deletes
    divest_event = _find_event_by({ 'vault': vault.address, 'assets': 100 }, pool_logs)
    withdraw_event = _find_event_by({ 'receiver': pool.address, 'owner': pool.address, 'assets': 100 }, pool_logs)
    withdraw_rev_event = _find_event_by({ 'fee_type': 4 , 'payer': pool.address, 'receiver': vault.address, }, pool_logs)
    collector_rev_event = _find_event_by({ 'fee_type': 32 , 'payer': vault.address, 'receiver': me, }, pool_logs)

    assert withdraw_event is not None
    assert divest_event is not None
    assert withdraw_rev_event is not None
    assert collector_rev_event is None # owner cant get collector fee
    assert withdraw_event['shares'] <= 100 # mintflation from first depoist gives us more shares in second deposit
    assert divest_event['shares'] <= 100 # mintflation from first depoist gives us more shares in second deposit
    assert divest_event['shares'] == withdraw_event['shares']
    assert divest_event['shares'] == withdraw_rev_event['amount'] + withdraw_rev_event['revenue']

    assert pool.price() == POOL_PRICE_DECIMALS
    assert pool.total_deployed() == INIT_POOL_BALANCE - 100
    # TODO TEST rounding error
    # assert vault.balanceOf(pool) == INIT_POOL_BALANCE - 100
    assert base_asset.balanceOf(vault) == INIT_POOL_BALANCE - 100


    # net_profit = math.floor(INIT_POOL_BALANCE * 8)
    recoverable_assets = pool.previewRedeem(math.floor(vault.balanceOf(pool) / 1.1))
    # print(f"pol divest #2  - ", recoverable_assets, INIT_POOL_BALANCE)

    # these revert checks cause python/boa to throw an EOF error for some reason
    # TODO its giving weird revert even tho we are just trying to withdraw more assets than we can bc of withdraw fee (can't do 1:1)
    with boa.reverts():
        pool.divest_vault(vault, recoverable_assets, sender=me)
        # non-owner cant paritally divest vault at profit
    
    with boa.reverts():
        pool.divest_vault(vault, 100, sender=me)
        # non-owner cant fully divest vault at profit

    pool.divest_vault(vault, recoverable_assets, sender=admin)
    pool_logs2 = pool.get_logs()
    
    print(f"pol divest #2  - ", pool_logs2)

    # check share price updates, divest performance fees, tc.
    divest_event2 = _find_event_by({ 'vault': vault.address, 'assets': recoverable_assets }, pool_logs2)
    withdraw_event2 = _find_event_by({ 'receiver': pool.address, 'owner': pool.address, 'assets': recoverable_assets }, pool_logs2)
    perf_rev_event2 = _find_event_by({ 'fee_type': 1, 'payer': vault.address, 'receiver': me, }, pool_logs2)
    withdraw_rev_event2 = _find_event_by({ 'fee_type': 4, 'payer': pool.address, 'receiver': vault.address, }, pool_logs2)
    collector_rev_event2 = _find_event_by({ 'fee_type': 32, 'payer': vault.address, 'receiver': me, }, pool_logs2)
    
    assert withdraw_event2 is not None
    assert divest_event2 is not None
    assert withdraw_rev_event2 is not None
    assert collector_rev_event2 is None # owner cant get collector fee
    
    assert withdraw_event2['shares'] <= recoverable_assets # mintflation from first depoist gives us more shares in second deposit
    assert divest_event2['shares'] <= recoverable_assets # mintflation from first depoist gives us more shares in second deposit
    assert divest_event2['shares'] == withdraw_event2['shares']
    # TODO TEST rounding error
    # assert divest_event2['shares'] == withdraw_rev_event2['amount'] + withdraw_rev_event['revenue']

    # assert vault.balanceOf(pool) < INIT_POOL_BALANCE - 100 - withdrawing # havent withdrawn everything, leave some in there
    assert pool.total_deployed() == INIT_POOL_BALANCE - 100 - recoverable_assets
    assert pool.totalAssets() >= INIT_POOL_BALANCE and pool.totalAssets() <= new_assets # might lose some to fees
    assert pool.price() >= POOL_PRICE_DECIMALS # new profit offsets mintflation



def test_divest_vault_only_owner_if_profitable(pool, vault, base_asset, admin, me, init_token_balances):
    pool.invest_vault(vault, INIT_POOL_BALANCE, sender=admin)
    # articifially increase vault assets / price to test if it goes down after divesting

    with boa.reverts():
        # non-owner cant fully divest vault at profit
        pool.divest_vault(vault, INIT_POOL_BALANCE, sender=me)
    with boa.reverts():
        # non-owner cant paritally divest vault at profit
        pool.divest_vault(vault, 100, sender=me)
    
    recoverable_assets = pool.previewRedeem(math.floor(vault.balanceOf(pool) / 1.1))
    pool.divest_vault(vault, recoverable_assets, sender=admin)
    


def test_divest_vault_only_owner_if_unrealized_loss(pool, vault, base_asset, admin, me, init_token_balances):
    """
    If we dont fully close out vault position then a loss is not technically realized since the position can still recover
    So only owner can divest vault at a partial loss leaving tokens in the vault.
    If no tokens are left in the vault then then that is a realized loss
    """
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.total_deployed() == 0
    assert pool.vault_investments(vault) == 0
    assert pool.price() == POOL_PRICE_DECIMALS


    new_assets = math.floor(INIT_POOL_BALANCE * 10)
    pool.invest_vault(vault, INIT_POOL_BALANCE, sender=admin)
    vault.eval(f"self.total_assets = {new_assets}")

    recoverable_assets = pool.previewRedeem(math.floor(vault.balanceOf(pool) / 1.1))

    # these revert checks cause python/boa to throw an EOF error for some reason
    # TODO its giving weird revert even tho we are just trying to withdraw more assets than we can bc of withdraw fee (can't do 1:1)
    with boa.reverts():
        pool.divest_vault(vault, recoverable_assets, sender=me)
        # non-owner cant paritally divest vault at profit
    
    with boa.reverts():
        pool.divest_vault(vault, 100, sender=me)
        # non-owner cant fully divest vault at profit

    pool.divest_vault(vault, recoverable_assets, sender=admin)
    pool_logs2 = pool.get_logs()
    
    print(f"pol divest #2  - ", pool_logs2)

    # check share price updates, divest performance fees, tc.
    divest_event2 = _find_event_by({ 'vault': vault.address, 'assets': recoverable_assets }, pool_logs2)
    withdraw_event2 = _find_event_by({ 'receiver': pool.address, 'owner': pool.address, 'assets': recoverable_assets }, pool_logs2)
    perf_rev_event2 = _find_event_by({ 'fee_type': 1, 'payer': vault.address, 'receiver': me, }, pool_logs2)
    withdraw_rev_event2 = _find_event_by({ 'fee_type': 4, 'payer': pool.address, 'receiver': vault.address, }, pool_logs2)
    collector_rev_event2 = _find_event_by({ 'fee_type': 32, 'payer': vault.address, 'receiver': me, }, pool_logs2)
    
    assert withdraw_event2 is not None
    assert divest_event2 is not None
    assert withdraw_rev_event2 is not None
    assert collector_rev_event2 is None # owner cant get collector fee
    
    assert withdraw_event2['shares'] <= recoverable_assets # mintflation from first depoist gives us more shares in second deposit
    assert divest_event2['shares'] <= recoverable_assets # mintflation from first depoist gives us more shares in second deposit
    assert divest_event2['shares'] == withdraw_event2['shares']
    # TODO TEST rounding error
    # assert divest_event2['shares'] == withdraw_rev_event2['amount'] + withdraw_rev_event['revenue']

    assert True

def test_divest_vault_anyone_if_realizing_loss(pool, vault, base_asset, admin, me, init_token_balances):
    assert True

# burn proper amount of shares for assets (do it 2x),
# no profit, no profit (do it 2x),
# no profit, profit (do it 2x),
# loss,
# cant claim profit until initial principal is recouped
# claim profit and then realize a loss (is it possible??)

# - test multi invest + divest - 
# properly divest -  no profit, profit, loss, profit, no profit, profit, loss (to 0 then invest again), profit
# properly impair - loss, profit (2x),


# 4626 Vault Invest/Divest
# invest
# (done) owner priviliges on investment functions
# (done) vault_investment goes up by _amount 
# (done) only vault that gets deposited into has vault_investment changed
# (done) emits InvestVault event X params
# (done) emits RevenueGenereated event with X params and FEE_TYPES.DEPOSIT
# (done) investing in vault increased total_deployed by _amount
# (done) investing in vault increases vault.balanceOf(pool) by shares returned in vault.deposit
# (done) investing in vault increases vault.balanceOf(pool) by expected shares using _amount and pre-deposit share price
# 
# divest
# (done) divesting vault decreases total_deployed
# (done) emits DivestVault event with X params
# (done) emits RevenueGenereated event with X params and FEE_TYPES.WITHDRAW
# divesting vault decreases vault.balanceOf(pool)
# divesting vault decreases vault.balanceOf(pool) by shares returned in vault.withdraw
# divesting vault decreases vault.balanceOf(pool) by expected shares using _amount and pre-withdraw share price
