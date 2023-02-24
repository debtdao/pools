import boa
import ape
import pytest
import math
import logging
from datetime import timedelta
from hypothesis import given, settings
from hypothesis import strategies as st
from ..conftest import INIT_POOL_BALANCE
from ..utils.events import _find_event

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
MAX_UINT = 115792089237316195423570985008687907853269984665640564039457584007913129639935
FEE_COEFFICIENT = 10000 # 100% in bps
MAX_PITTANCE_FEE = 200 # 2% in bps

# TODO Ask ChatGPT to generate test cases in vyper
# TODO copy test over  https://github.com/fubuloubu/ERC4626/blob/main/tests/test_methods.py

# TEST all 4626 unit tests on preview functions. then compare preview func to actual action func 
# (only diff between preview and action is side effects - state and events 

@pytest.mark.ERC4626
def test_first_depositor_state_changes(pool, admin, me, init_token_balances):
    """
    Test share price before and after first person enters the pool
    init_token_balances does deposit flow in ../conftest.py
    """
    assert pool.totalSupply() == init_token_balances * 2
    assert pool.totalAssets() == init_token_balances * 2
    # 1:1 initial backing
    assert pool.totalSupply() == pool.totalAssets()
    assert pool.price() == 1
    # shares split equally, no price difference
    assert pool.balanceOf(admin) == init_token_balances
    assert pool.balanceOf(me) == init_token_balances


@pytest.mark.ERC4626
@given(amount=st.integers(min_value=0, max_value=10**25),
        # total pool assets/shares to manipulate share price
        assets=st.integers(min_value=0, max_value=10**25),
        shares=st.integers(min_value=0, max_value=10**25),
        deposit_fee=st.integers(min_value=1, max_value=MAX_PITTANCE_FEE))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_deposit(pool, base_asset, me, admin, init_token_balances,
                amount, assets, shares, deposit_fee):
    """
    Test share price before and after first person enters the pool
    init_token_balances does deposit flow in ../conftest.py
    """
    assert pool.balanceOf(me) == init_token_balances
    base_asset.mint(me, amount)
    new_balance = init_token_balances + amount
    assert base_asset.balanceOf(me) == new_balance
    
    # handle fuzzing vars math for share price
    expected_share_price = 1
    if shares == 0 or assets == 0: # nothing to price
        expected_share_price = 1
    elif assets / shares < 1: # fixed point math round down
        expected_share_price = 0
        return # unusable test if no share price
        # TODO What happens in contract if share price == 0 ????
    else:
        # expected_share_price = round(assets / shares)
        # evm always rounds down
        expected_share_price = math.floor(assets / shares)


    #  manipulate pool shares/assets to get target share price
    pool.eval(f'self.total_assets = {assets}')
    pool.eval(f'self.total_supply = {shares}')
    share_price = pool.price() # pre deposit price is used in _deposit() for calculating shares returned

    if share_price == 0:
        return # cant deposit if no price

    # _assert_uint_with_rounding(share_price, expected_share_price)

    # fees_generated = round((amount * deposit_fee) / FEE_COEFFICIENT / share_price)
    fees_generated = math.floor((amount * deposit_fee) / FEE_COEFFICIENT / share_price) 
    pool.eval(f'self.fees.deposit = {deposit_fee}')

    base_asset.approve(pool, amount, sender=me) 
    shares_created = pool.deposit(amount, me, sender=me) 

    # TODO TEST event emissions
    # TODO python bug on get_logs(). `Error: cant cast to Int`
    logs = pool.get_logs()
    print(logs) 
    print("deposit logs", logs[0], logs[1])
    deposit_event = _find_event('Deposit', logs)
    deposit_rev_event = _find_event('RevenueGenerated', logs)
    print("deposit logs named", deposit_event, deposit_rev_event)


    # # INIT_USER_POOL_BALANCE = round(amount / share_price)
    # INIT_USER_POOL_BALANCE = math.floor(amount / share_price)
    # # ensure right price for shares
    # # accomodate evm vs python rounding differences
    # _assert_uint_with_rounding(shares_created, INIT_USER_POOL_BALANCE)
    # # ensure shares got minted to right person
    # _assert_uint_with_rounding(pool.balanceOf(me), INIT_USER_POOL_BALANCE)
    # # ensure supply was inflated by deposit + fee
    # expected_total_supply = shares + shares_created + fees_generated
    # _assert_uint_with_rounding(pool.totalSupply(), expected_total_supply)

@pytest.mark.ERC4626
@given(amount=st.integers(min_value=0, max_value=10**25),
        # total pool assets/shares to manipulate share price
        assets=st.integers(min_value=0, max_value=10**25),
        shares=st.integers(min_value=0, max_value=10**25),
        withdraw_fee=st.integers(min_value=1, max_value=MAX_PITTANCE_FEE))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_withdraw(
    pool, base_asset, me, admin, init_token_balances,
    amount, assets, shares, withdraw_fee,
):
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE

    if assets > INIT_USER_POOL_BALANCE:
        with boa.reverts(): # TODO TEST custom errors
            pool.withdraw(assets, me, me, sneder=me)
            
    shares_withdrawn = pool.withdraw(assets, me, me, sneder=me)
    
    # TODO TEST event emissions
    # get events before calling other pool functions which will erase them
    # TODO python bug on get_logs(). `Error: cant cast to Int`
    logs = pool.get_logs()
    print(logs) 
    print("withdraw logs", logs[0], logs[1])
    deposit_event = _find_event('Deposit', logs)
    deposit_rev_event = _find_event('RevenueGenerated', logs)
    print("withdraw logs named", deposit_event, deposit_rev_event)

    assert pool.totalAssets() == INIT_POOL_BALANCE - assets
    assert pool.totalSupply() == INIT_POOL_BALANCE - assets
    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE - assets # ensure shares burned from right person

    # expected_shares = round(amount / share_price)
    # ensure right price for shares
    # accomodate evm vs python rounding differences
    assert shares_withdrawn == INIT_USER_POOL_BALANCE
    # ensure supply was inflated by deposit + fee
    expected_total_supply = shares + shares_withdrawn + fees_generated
    assert pool.totalSupply() == expected_total_supply

@pytest.mark.ERC4626
@given(amount=st.integers(min_value=0, max_value=10**25),
        # total pool assets/shares to manipulate share price
        assets=st.integers(min_value=0, max_value=10**25),
        shares=st.integers(min_value=0, max_value=10**25),
        withdraw_fee=st.integers(min_value=1, max_value=MAX_PITTANCE_FEE))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_withdraw_with_approval(
    pool, base_asset, me, admin, init_token_balances,
    amount, assets, shares, withdraw_fee,
):
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE

    pool.approve(admin, assets, sender=me)
    
    if assets > INIT_USER_POOL_BALANCE:
        with boa.reverts(): # TODO TEST custom errors
            pool.withdraw(assets, me, me, sneder=admin)
            
    shares_withdrawn = pool.withdraw(assets, me, me, sneder=admin)
    
   
    # TODO TEST event emissions
    # get events before calling other pool functions which will erase them
    # TODO python bug on get_logs(). `Error: cant cast to Int`
    logs = pool.get_logs()
    print(logs) 
    print("withdraw logs", logs[0], logs[1])
    deposit_event = _find_event('Deposit', logs)
    deposit_rev_event = _find_event('RevenueGenerated', logs)
    print("withdraw logs named", deposit_event, deposit_rev_event)

    assert pool.totalAssets() == INIT_POOL_BALANCE - assets
    assert pool.totalSupply() == INIT_POOL_BALANCE - assets
    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE - assets # ensure shares burned from right person


@pytest.mark.ERC4626
@given(amount=st.integers(min_value=0, max_value=(MAX_UINT / 4) * 3),)
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_deposit_cant_cause_total_asset_overflow(pool, base_asset, me, admin, init_token_balances, amount):
    init_pool_deposits = init_token_balances * 2
    max_avail = min(amount, MAX_UINT - init_pool_deposits)
    
    assert pool.totalAssets() == init_pool_deposits # ensure clean state
    base_asset.mint(me, max_avail, sender=me) # do + 1 to test max overflow
    base_asset.approve(pool, max_avail, sender=me)
    pool.deposit(max_avail, me, sender=me)
    assert pool.totalAssets() == init_pool_deposits + max_avail # ensure clean state

    overflow_amnt = MAX_UINT - max_avail
    
    with boa.reverts():
        # cant exceed max_uint before we even populate tx
        # TODO test python/eth_abi reverts not boa
        base_asset.mint(me, overflow_amnt, sender=me) # do + 1 to test max overflow
        base_asset.approve(pool, overflow_amnt, sender=me)

    
    with boa.reverts():
        # deposit fails bc we cant approve required amount
        # TODO TEST is only important here, need to check that unchecked math or something
        # doesnt fuck up in our contract, regardless of base_asset logic
        pool.deposit(overflow_amnt, me, sender=me)


@pytest.mark.ERC4626
@given(shares=st.integers(min_value=0, max_value=MAX_UINT / 2),
       assets=st.integers(min_value=0, max_value=MAX_UINT,))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_invariant_preview_equals_wirtual_share_price(pool, base_asset, me, admin, shares, assets):
    pool.eval(f"self.total_assets = {assets}")
    pool.eval(f"self.total_supply = {shares}")
    pool.eval(f"self.balances[{me}] = {shares}")
    price = pool.price()


    redeemable = pool.previewRedeem(shares)
    withdrawable = pool.previewWithdraw(assets)
    assert redeemable == shares
    assert withdrawable == shares

    mintable = pool.previewMint(shares)
    depositable = pool.previewDeposit(assets)
    assert mintable == (0 if shares == 0 else shares)
    assert depositable == assets
    
    if assets > 0:
        pool.eval(f"self.total_deployed = {assets - 1}")
        redeemable = pool.previewRedeem(shares)
        withdrawable = pool.previewWithdraw(assets)
        # 4626 spec saysdont account for user+global limits so doesnt account for liquid pool
        assert redeemable ==  shares
        assert withdrawable == shares




    ## TODO TEST account for deposit/withdraw feesset fees to 0
    # make separate test that preview propely accounts for withdraw fees. that should be 4626


    
@pytest.mark.ERC4626
@given(shares=st.integers(min_value=10**18, max_value=MAX_UINT / 2),
       assets=st.integers(min_value=1, max_value=MAX_UINT / 2),
        pittance_fee=st.integers(min_value=0, max_value=MAX_PITTANCE_FEE),)
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_invariant_preview_equals_realized_share_price(
    pool, base_asset, me, admin,
    shares, assets, pittance_fee,
):
    """
    we do not take 
    """
    def reset():
        pool.eval(f"self.total_assets = {assets}")
        pool.eval(f"self.total_supply = {shares}")
        pool.eval(f"self.balances[{me}] = {shares}")
        # print("reset pool vals", pool.totalSupply(), pool.totalAssets())
        
    reset()
    redeemable = pool.previewRedeem(shares, sender=me)
    withdrawable = pool.previewWithdraw(assets, sender=me)
    print("reset pool vals", pool.totalSupply(), pool.totalAssets(), assets)
    redeemed = pool.redeem(shares, me, me, sender=me)
    reset()
    withdrawn = pool.withdraw(assets, me, me, sender=me)

    assert redeemable == redeemed
    assert withdrawable == withdrawn

    pool.eval(f"self.fees.withdraw = {pittance_fee}")

    reset()
    redeemable = pool.previewRedeem(shares, sender=me)
    withdrawable = pool.previewWithdraw(assets, sender=me)
    redeemed = pool.redeem(shares, me, me, sender=me)
    reset()
    withdrawn = pool.withdraw(assets, me, me, sender=me)
    reset()

    assert redeemable == redeemed
    assert withdrawable == withdrawn


    reset()
    mintable = pool.previewMint(shares, sender=me)
    depositable = pool.previewDeposit(assets, sender=me)
    minted = pool.mint(shares, me, sender=me)
    reset()
    deposited = pool.deposit(assets, me, sender=me)
    reset()
    assert mintable == minted
    assert depositable == deposited
    
    pool.eval(f"self.fees.deposit = {pittance_fee}")

    reset()
    mintable = pool.previewMint(shares, sender=me)
    depositable = pool.previewDeposit(assets, sender=me)
    minted = pool.mint(shares, me, sender=me)
    reset()
    deposited = pool.deposit(assets, me, sender=me)
    reset()
    assert mintable == minted
    assert depositable == deposited

# (done) preview functions - right share price return value
# (semi-done)preview functions - proper fees calculated
# (done) preview -> action equality
# (done) mint/redeem + deposit/withdraw equality (incl fees)

# TEST all events properly emitted 
# deposit/withdraw


# TEST invariants
# (done) total supply with mint/burn

@pytest.mark.ERC4626
@given(assets=st.integers(min_value=1, max_value=MAX_UINT / 2),)
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_invariant_total_supply_matches_mint_and_burn(
    pool, base_asset, me, admin,
    assets,
):
    pool.eval(f"self.total_assets = 0")
    pool.eval(f"self.total_supply = 0")
    assert pool.totalSupply() == 0

    base_asset.mint(me, assets)
    base_asset.approve(pool, assets, sender=me)
    
    pool.deposit(assets, me, sender=me)
    assert pool.totalSupply() == assets

    shares = pool.withdraw(assets, me, me, sender=me)
    assert pool.totalSupply() == 0


    base_asset.approve(pool, assets, sender=me)
    pool.mint(shares, me, sender=me)
    assert pool.totalSupply() == assets

    pool.redeem(shares, me, me, sender=me)
    assert pool.totalSupply() == 0
    


# https://github.com/fubuloubu/ERC4626/blob/main/tests/test_methods.py