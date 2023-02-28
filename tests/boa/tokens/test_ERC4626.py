import boa
import ape
import pytest
import math
import logging
from datetime import timedelta
from hypothesis import given, settings
from hypothesis import strategies as st
from eth_utils import to_checksum_address
from ..conftest import INIT_POOL_BALANCE, INIT_USER_POOL_BALANCE
from ..utils.events import _find_event

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
MAX_UINT = 115792089237316195423570985008687907853269984665640564039457584007913129639935
FEE_COEFFICIENT = 10000 # 100% in bps
MAX_PITTANCE_FEE = 200 # 2% in bps

# TODO Ask ChatGPT to generate test cases in vyper
# TODO copy test over  https://github.com/fubuloubu/ERC4626/blob/main/tests/test_methods.py

# TEST all 4626 unit tests on preview functions. then compare preview func to actual action func 
# (only diff between preview and action is side effects - state and events 
# 	Verify that the deposit and withdraw business logic is consistent and symmetrical, especially when re-sending tokens to the same address (from == to).

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

    # deposit fails if we havent approved base tokens to pool yet
    if amount > 0: # TODO TEST is it ok that 0 doesnt revert?
        with boa.reverts():
            pool.deposit(amount, me, sender=me) 

    base_asset.approve(pool, amount, sender=me) 
    shares_created = pool.deposit(amount, me, sender=me) 

    # TODO TEST event emissions
    # TODO python bug on get_logs(). `Error: cant cast to Int`
    logs = pool.get_logs()
    deposit_event = _find_event('Deposit', logs)
    deposit_rev_event = _find_event('RevenueGenerated', logs)
    print("deposit logs named", deposit_event, deposit_rev_event)

    assert to_checksum_address(deposit_event.args_map['owner']) == me
    assert to_checksum_address(deposit_event.args_map['sender']) == me
    
    if shares > 0:
        assert deposit_event.args_map['assets'] == amount
        assert deposit_event.args_map['shares'] == shares_created

    assert deposit_rev_event.args_map['fee_type'] == 2
    assert deposit_rev_event.args_map['amount'] == shares_created
    assert deposit_rev_event.args_map['revenue'] == pool.accrued_fees()
    assert to_checksum_address(deposit_rev_event.args_map['payer']) == pool.address
    assert to_checksum_address(deposit_rev_event.args_map['token']) == pool.address
    assert to_checksum_address(deposit_rev_event.args_map['receiver']) == pool.owner()

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
        deposit_fee=st.integers(min_value=1, max_value=MAX_PITTANCE_FEE))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_mint(pool, base_asset, me, admin, init_token_balances,
                amount, assets, shares, deposit_fee):
    """
    Test share price before and after first person enters the pool
    init_token_balances does deposit flow in ../conftest.py
    """

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

    # assert expected_share_price == share_price

    assert pool.balanceOf(me) == init_token_balances
    assets_for_shares = amount * share_price
    base_asset.mint(me, amount * share_price)
    new_balance = init_token_balances + assets_for_shares
    assert base_asset.balanceOf(me) == new_balance

    if share_price == 0:
        return # cant deposit if no price

    # _assert_uint_with_rounding(share_price, expected_share_price)

    # fees_generated = round((amount * deposit_fee) / FEE_COEFFICIENT / share_price)
    fees_generated = math.floor((amount * deposit_fee) / FEE_COEFFICIENT / share_price) 
    pool.eval(f'self.fees.deposit = {deposit_fee}')
    
    # deposit fails if we havent approved base tokens yet
    if amount > 0:
        with boa.reverts():
            pool.mint(amount, me, sender=me) 

    base_asset.approve(pool, assets_for_shares, sender=me) 
    assets_deposited = pool.mint(amount, me, sender=me)

    # TODO TEST event emissions
    # TODO python bug on get_logs(). `Error: cant cast to Int`
    logs = pool.get_logs()
    mint_event = _find_event('Deposit', logs)
    mint_rev_event = _find_event('RevenueGenerated', logs)
    print("mint logs named", mint_event, mint_rev_event)

    assert to_checksum_address(mint_event.args_map['owner']) == me
    assert to_checksum_address(mint_event.args_map['sender']) == me
    assert mint_event.args_map['assets'] == assets_for_shares
    assert mint_event.args_map['shares'] == amount

    assert mint_rev_event.args_map['fee_type'] == 2
    assert mint_rev_event.args_map['amount'] == amount
    assert mint_rev_event.args_map['revenue'] == pool.accrued_fees()
    assert to_checksum_address(mint_rev_event.args_map['payer']) == pool.address
    assert to_checksum_address(mint_rev_event.args_map['token']) == pool.address
    assert to_checksum_address(mint_rev_event.args_map['receiver']) == pool.owner()


@pytest.mark.ERC4626
@given(amount=st.integers(min_value=0, max_value=10**25),
        # total pool assets/shares to manipulate share price
        assets=st.integers(min_value=0, max_value=10**24),
        shares=st.integers(min_value=0, max_value=10**25),
        withdraw_fee=st.integers(min_value=1, max_value=MAX_PITTANCE_FEE))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_withdraw(
    pool, base_asset, me, admin, init_token_balances,
    amount, assets, shares, withdraw_fee,
):
    user_asset_balance = base_asset.balanceOf(me)
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE

    pool.eval(f"self.fees.withdraw = {withdraw_fee}")

    if amount > INIT_USER_POOL_BALANCE:
        with boa.reverts(): # TODO TEST custom errors
            pool.withdraw(amount, me, me, sender=me)

    shares_withdrawn = pool.withdraw(amount, me, me, sender=me)
    
    # NOTE: MUST test events immediately after tx else boa deletes.
    logs = pool.get_logs()

    withdraw_event = _find_event('Withdraw', logs)
    assert to_checksum_address(withdraw_event.args_map['owner']) == me
    assert to_checksum_address(withdraw_event.args_map['sender']) == me
    assert to_checksum_address(withdraw_event.args_map['receiver']) == me
    assert withdraw_event.args_map['assets'] == amount
    assert withdraw_event.args_map['shares'] == shares_withdrawn

    withdraw_rev_event = _find_event('RevenueGenerated', logs)
    assert withdraw_rev_event.args_map['fee_type'] == 4
    assert withdraw_rev_event.args_map['amount'] == amount
    assert withdraw_rev_event.args_map['revenue'] == shares_withdrawn - amount
    assert to_checksum_address(withdraw_rev_event.args_map['payer']) == me
    assert to_checksum_address(withdraw_rev_event.args_map['token']) == pool.address
    assert to_checksum_address(withdraw_rev_event.args_map['receiver']) == pool.address

    assert pool.totalAssets() == INIT_POOL_BALANCE - amount
        

    assert pool.totalAssets() == INIT_POOL_BALANCE - amount
    assert pool.totalSupply() == INIT_POOL_BALANCE - shares_withdrawn

    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE - amount # ensure shares burned from right person


    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE - shares_withdrawn
    assert base_asset.balanceOf(me) == user_asset_balance + amount

    # burn more shares than amount even tho share price is 1
    if withdraw_fee == 0:
        assert pool.price() == 1
    else:
        assert pool.price() <= 1 # TODO price will always be 0 if < 1:1 backing

    if withdraw_fee > 0 and amount > FEE_COEFFICIENT:
        min_shares_withdrawn = math.floor(amount + (amount * withdraw_fee / FEE_COEFFICIENT)) - 10
        assert shares_withdrawn > amount and shares_withdrawn >= min_shares_withdrawn


@pytest.mark.ERC4626
@given(amount=st.integers(min_value=0, max_value=10**25),
        # total pool assets/shares to manipulate share price
        assets=st.integers(min_value=0, max_value=10**24),
        shares=st.integers(min_value=0, max_value=10**25),
        withdraw_fee=st.integers(min_value=1, max_value=MAX_PITTANCE_FEE))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_withdraw_with_approval(
    pool, base_asset, me, admin, init_token_balances,
    amount, assets, shares, withdraw_fee,
):
    user_asset_balance = base_asset.balanceOf(me)
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE

    pool.approve(admin, amount, sender=me)
    
    pool.eval(f"self.fees.withdraw = {withdraw_fee}")

    if amount > INIT_USER_POOL_BALANCE:
        with boa.reverts(): # TODO TEST custom errors
            pool.withdraw(amount, me, me, sender=admin)

    # TODO TEST modify share price with assets/shares and ensure math is right            
    shares_withdrawn = pool.withdraw(amount, me, me, sender=admin)

    # NOTE: MUST test events immediately after tx else boa deletes.
    logs = pool.get_logs()
    
    withdraw_event = _find_event('Withdraw', logs)
    assert to_checksum_address(withdraw_event.args_map['owner']) == me
    assert to_checksum_address(withdraw_event.args_map['sender']) == admin
    assert to_checksum_address(withdraw_event.args_map['receiver']) == me
    assert withdraw_event.args_map['assets'] == assets
    assert withdraw_event.args_map['shares'] == shares_withdrawn 

    withdraw_rev_event = _find_event('RevenueGenerated', logs)
    assert to_checksum_address(withdraw_rev_event.args_map['payer']) == me
    assert to_checksum_address(withdraw_rev_event.args_map['token']) == pool.address
    assert to_checksum_address(withdraw_rev_event.args_map['receiver']) == pool.address
    assert withdraw_rev_event.args_map['amount'] == amount # fees are on original shares, bc shares_withdrawn incl fees
    assert withdraw_rev_event.args_map['fee_type'] == 4 # index 2 in pool.FEE_TYPES
    assert withdraw_rev_event.args_map['revenue'] == shares_withdrawn - amount

    assert pool.totalAssets() == INIT_POOL_BALANCE - amount
    assert pool.totalSupply() == INIT_POOL_BALANCE - shares_withdrawn
    
    if withdraw_fee > 0 and amount > FEE_COEFFICIENT:
        assert shares_withdrawn > amount

    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE - shares_withdrawn
    assert base_asset.balanceOf(me) == user_asset_balance + amount



@pytest.mark.ERC4626
@given(amount=st.integers(min_value=0, max_value=10**25),
        # total pool assets/shares to manipulate share price
        assets=st.integers(min_value=0, max_value=10**24),
        shares=st.integers(min_value=0, max_value=10**25),
        withdraw_fee=st.integers(min_value=1, max_value=MAX_PITTANCE_FEE))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_redeem(
    pool, base_asset, me, admin, init_token_balances,
    amount, assets, shares, withdraw_fee,
):
    user_asset_balance = base_asset.balanceOf(me)
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE

    pool.eval(f"self.fees.withdraw = {withdraw_fee}")

    if amount > INIT_USER_POOL_BALANCE:
        with boa.reverts(): # TODO TEST custom errors
            pool.withdraw(amount, me, me, sender=me)

    assets_withdrawn = pool.redeem(amount, me, me, sender=me)
    
    # NOTE: MUST test events immediately after tx else boa deletes.
    logs = pool.get_logs()

    redeem_event = _find_event('Withdraw', logs)
    assert to_checksum_address(redeem_event.args_map['owner']) == me
    assert to_checksum_address(redeem_event.args_map['sender']) == me
    assert to_checksum_address(redeem_event.args_map['receiver']) == me
    assert redeem_event.args_map['assets'] == amount
    assert redeem_event.args_map['shares'] == assets_withdrawn

    redeem_rev_event = _find_event('RevenueGenerated', logs)
    assert redeem_rev_event.args_map['fee_type'] == 4
    assert redeem_rev_event.args_map['amount'] == amount
    assert redeem_rev_event.args_map['revenue'] == amount - assets_withdrawn
    assert to_checksum_address(redeem_rev_event.args_map['payer']) == me
    assert to_checksum_address(redeem_rev_event.args_map['token']) == pool.address
    assert to_checksum_address(redeem_rev_event.args_map['receiver']) == pool.address

    assert pool.totalAssets() == INIT_POOL_BALANCE - amount
        

    assert pool.totalAssets() == INIT_POOL_BALANCE - amount
    assert pool.totalSupply() == INIT_POOL_BALANCE - assets_withdrawn

    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE - amount # ensure shares burned from right person


    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE - assets_withdrawn
    assert base_asset.balanceOf(me) == user_asset_balance + amount

    # burn more shares than amount even tho share price is 1
    if withdraw_fee == 0:
        assert pool.price() == 1
    else:
        assert pool.price() <= 1 # TODO price will always be 0 if < 1:1 backing

    if withdraw_fee > 0 and amount > FEE_COEFFICIENT:
        min_amount_withdrawn = math.floor(amount + (amount * withdraw_fee / FEE_COEFFICIENT)) - 10
        assert assets_withdrawn > amount and assets_withdrawn >= min_amount_withdrawn


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
        # TODO TEST python/eth_abi reverts not boa
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
def test_invariant_preview_equals_virtual_share_price(pool, base_asset, me, admin, shares, assets):
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

    ## TODO TEST account for deposit/withdraw fees set fees to 0


    
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

    # TODO add more assertions with deposit+withdraw fees
    


# https://github.com/fubuloubu/ERC4626/blob/main/tests/test_methods.py