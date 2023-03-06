import boa
import ape
import pytest
import math
import logging
from datetime import timedelta
from hypothesis import given, settings
from hypothesis import strategies as st
from eth_utils import to_checksum_address
from ..conftest import POOL_PRICE_DECIMALS, INIT_POOL_BALANCE, INIT_USER_POOL_BALANCE
from ..utils.price import _calc_price, _to_assets, _to_shares, _calc_fee
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

# add test that cant deposit with 0 address as receiver
# test that _convert_to_assets/shares works as expected whether share price is over/under 1:1


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
    assert pool.price() == POOL_PRICE_DECIMALS
    # shares split equally, no price difference
    assert pool.balanceOf(admin) == init_token_balances
    assert pool.balanceOf(me) == init_token_balances


@pytest.mark.ERC4626
@given(amount=st.integers(min_value=1, max_value=10**25),
        # total pool assets/shares to manipulate share price
        assets=st.integers(min_value=100, max_value=10**25),
        shares=st.integers(min_value=1, max_value=10**25),
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
    expected_share_price = _calc_price(assets, shares)
    if shares == 0 or assets == 0: # nothing to price
        expected_share_price = 1
    elif assets / shares < 1: # fixed point math round down
        expected_share_price = 0
        return # unusable test if no share price
        # TODO What happens in contract if share price == 0 ????


    #  manipulate pool shares/assets to get target share price
    pool.eval(f'self.total_assets = {assets}')
    pool.eval(f'self.total_supply = {shares}')
    share_price = pool.price() # pre deposit price is used in _deposit() for calculating shares returned

    # if share_price == 0:
    #     return # cant deposit if no price

    # TODO TEST fix rounding errors
    # assert expected_share_price == share_price

    # fees_generated = round((amount * deposit_fee) / FEE_COEFFICIENT / share_price)
    fees_generated = math.floor((amount * deposit_fee) / FEE_COEFFICIENT / share_price) 
    pool.eval(f'self.fees.deposit = {deposit_fee}')

    # deposit fails if we `amount` gets us no shares back bc price too high
    expected_shares = _to_shares(amount, share_price)
    if expected_shares <= 0: # TODO TEST is it ok that 0 doesnt revert?
        with boa.reverts():
            pool.deposit(amount, me, sender=me) 
        print(f"deposit failed, shares returned == 0 - amount/share_price {amount}/{share_price}")
        return

    # deposit fails if we havent approved base tokens to pool yet
    if amount > 0: # TODO TEST is it ok that 0 doesnt revert?
        with boa.reverts():
            pool.deposit(amount, me, sender=me) 

    base_asset.approve(pool, MAX_UINT, sender=me) 
    shares_created = pool.deposit(amount, me, sender=me) 

    # TODO TEST event emissions
    # TODO python bug on get_logs(). `Error: cant cast to Int`
    logs = pool.get_logs()
    deposit_event = _find_event('Deposit', logs)
    deposit_rev_event = _find_event('RevenueGenerated', logs)
    print("deposit logs named", deposit_event, deposit_rev_event)

    assert to_checksum_address(deposit_event.args_map['owner']) == me
    assert to_checksum_address(deposit_event.args_map['sender']) == me
    
    # if shares > 0:
    assert deposit_event.args_map['assets'] == amount
    assert deposit_event.args_map['shares'] == shares_created

    assert deposit_rev_event.args_map['fee_type'] == 2
    assert deposit_rev_event.args_map['amount'] == shares_created
    assert deposit_rev_event.args_map['revenue'] == pool.accrued_fees()
    assert to_checksum_address(deposit_rev_event.args_map['payer']) == pool.address
    assert to_checksum_address(deposit_rev_event.args_map['token']) == pool.address
    assert to_checksum_address(deposit_rev_event.args_map['receiver']) == pool.owner()

    assert base_asset.balanceOf(pool) == INIT_POOL_BALANCE + amount
    assert pool.totalSupply() == shares + shares_created + pool.accrued_fees()
    assert pool.balanceOf(me) == init_token_balances + shares_created
    # assert shares_created == expected_shares # TODO TEST rounding error


@pytest.mark.ERC4626
@given(amount=st.integers(min_value=1, max_value=10**25),
        # total pool assets/shares to manipulate share price
        assets=st.integers(min_value=100, max_value=10**25),
        shares=st.integers(min_value=1, max_value=10**25),
        deposit_fee=st.integers(min_value=1, max_value=MAX_PITTANCE_FEE))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_mint(pool, base_asset, me, admin, init_token_balances,
                amount, assets, shares, deposit_fee):
    """
    Test share price before and after first person enters the pool
    init_token_balances does deposit flow in ../conftest.py
    """
    # handle fuzzing vars math for share price
    expected_share_price = _calc_price(assets, shares)
    if shares == 0 or assets == 0: # nothing to price
        expected_share_price = POOL_PRICE_DECIMALS
    elif expected_share_price < 1: # fixed point math round down
        expected_share_price = 0
        return # unusable test if no share price
        # TODO What happens in contract if share price == 0 ????

    #  manipulate pool shares/assets to get target share price
    pool.eval(f'self.total_assets = {assets}')
    pool.eval(f'self.total_supply = {shares}')
    share_price = pool.price() # pre deposit price is used in _deposit() for calculating shares returned

    # TODO TEST fix rounding errors
    # assert expected_share_price == share_price

    assert pool.balanceOf(me) == init_token_balances
    assets_for_shares = _to_assets(amount, share_price)
    base_asset.mint(me, assets_for_shares)
    new_balance = init_token_balances + assets_for_shares
    assert base_asset.balanceOf(me) == new_balance

    if share_price == 0:
        with boa.reverts():
            pool.mint(amount, me, sender=me) 
        return # cant deposit if no price

    # fees_generated = math.floor((amount * deposit_fee) / FEE_COEFFICIENT / share_price) 
    fees_generated = math.floor(math.floor(amount * deposit_fee) / FEE_COEFFICIENT)
    pool.eval(f'self.fees.deposit = {deposit_fee}')
    
    # deposit fails if we havent approved base tokens yet
    if amount > 0:
        with boa.reverts():
            pool.mint(amount, me, sender=me) 

    # deposit fails if under minimum shares required
    if assets_for_shares < pool.min_deposit():
        with boa.reverts():
            pool.mint(amount, me, sender=me)
        print(f"deposit below min {assets_for_shares}/{pool.min_deposit()}/{amount}")
        return

    base_asset.approve(pool, MAX_UINT, sender=me) 
    assets_deposited = pool.mint(amount, me, sender=me)

    # TODO TEST event emissions
    # TODO python bug on get_logs(). `Error: cant cast to Int`
    logs = pool.get_logs()
    mint_event = _find_event('Deposit', logs)
    mint_rev_event = _find_event('RevenueGenerated', logs)
    print("mint logs named", mint_event, mint_rev_event)

    assert to_checksum_address(mint_event.args_map['owner']) == me
    assert to_checksum_address(mint_event.args_map['sender']) == me
    assert mint_event.args_map['assets'] == assets_deposited # TODO TEST rounding error `assets_for_shares`
    assert mint_event.args_map['shares'] == amount

    assert mint_rev_event.args_map['fee_type'] == 2
    assert mint_rev_event.args_map['amount'] == amount
    assert mint_rev_event.args_map['revenue'] == pool.accrued_fees()
    assert to_checksum_address(mint_rev_event.args_map['payer']) == pool.address
    assert to_checksum_address(mint_rev_event.args_map['token']) == pool.address
    assert to_checksum_address(mint_rev_event.args_map['receiver']) == pool.owner()


@pytest.mark.ERC4626
@given(amount=st.integers(min_value=1, max_value=10**25),
        # total pool assets/shares to manipulate share price
        assets=st.integers(min_value=100, max_value=10**24),
        shares=st.integers(min_value=1, max_value=10**25),
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
    pre_action_price = pool.price()
    assert pre_action_price == POOL_PRICE_DECIMALS

    pool.eval(f"self.fees.withdraw = {withdraw_fee}")

    if amount > INIT_USER_POOL_BALANCE:
        with boa.reverts(): # TODO TEST custom errors
            pool.withdraw(amount, me, me, sender=me)
        return # cant test bc redeem tx will revert
    
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
    assert withdraw_rev_event.args_map['revenue'] ==  _calc_fee(assets=amount, fee=withdraw_fee, price=pre_action_price)
    assert to_checksum_address(withdraw_rev_event.args_map['payer']) == me
    assert to_checksum_address(withdraw_rev_event.args_map['token']) == pool.address
    assert to_checksum_address(withdraw_rev_event.args_map['receiver']) == pool.address

    assert pool.totalAssets() == INIT_POOL_BALANCE - amount
        

    assert pool.totalAssets() == INIT_POOL_BALANCE - amount
    assert pool.totalSupply() == INIT_POOL_BALANCE - shares_withdrawn

    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE - amount # ensure shares burned from right person


    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE - shares_withdrawn
    assert base_asset.balanceOf(me) == user_asset_balance + amount
    
    
    # TODO TEST when we re-implement withdraw fees
    # burn more shares than amount even tho share price is 1
    if withdraw_fee == 0:
        assert pool.price() == POOL_PRICE_DECIMALS
    else:
        assert pool.price() >= POOL_PRICE_DECIMALS # TODO price will always be 0 if < 1:1 backing

    if withdraw_fee > 0 and amount > FEE_COEFFICIENT:
        min_shares_withdrawn = math.floor(amount + (amount * withdraw_fee / FEE_COEFFICIENT)) - 10
        assert shares_withdrawn < amount and shares_withdrawn <= min_shares_withdrawn


@pytest.mark.ERC4626
@given(amount=st.integers(min_value=1, max_value=10**25),
        # total pool assets/shares to manipulate share price
        assets=st.integers(min_value=100, max_value=10**24),
        shares=st.integers(min_value=1, max_value=10**25),
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

    # approve max bc they take `amount` + a withdraw fee` 
    pool.approve(admin, MAX_UINT, sender=me)
    
    pool.eval(f"self.fees.withdraw = {withdraw_fee}")

    if amount > INIT_USER_POOL_BALANCE:
        with boa.reverts(): # TODO TEST custom errors
            pool.withdraw(amount, me, me, sender=admin)
        return # cant test bc redeem tx will revert
    
    pre_action_price = pool.price()
    # TODO TEST modify share price with assets/shares and ensure math is right            
    shares_withdrawn = pool.withdraw(amount, me, me, sender=admin)

    # NOTE: MUST test events immediately after tx else boa deletes.
    logs = pool.get_logs()
    
    withdraw_event = _find_event('Withdraw', logs)
    assert to_checksum_address(withdraw_event.args_map['owner']) == me
    assert to_checksum_address(withdraw_event.args_map['sender']) == admin
    assert to_checksum_address(withdraw_event.args_map['receiver']) == me
    assert withdraw_event.args_map['assets'] == amount
    assert withdraw_event.args_map['shares'] == shares_withdrawn 

    withdraw_rev_event = _find_event('RevenueGenerated', logs)
    assert to_checksum_address(withdraw_rev_event.args_map['payer']) == me
    assert to_checksum_address(withdraw_rev_event.args_map['token']) == pool.address
    assert to_checksum_address(withdraw_rev_event.args_map['receiver']) == pool.address
    assert withdraw_rev_event.args_map['amount'] == amount # fees are on original shares, bc shares_withdrawn incl fees
    assert withdraw_rev_event.args_map['fee_type'] == 4 # index 2 in pool.FEE_TYPES
    assert withdraw_rev_event.args_map['revenue'] ==  _calc_fee(assets=amount, fee=withdraw_fee, price=pre_action_price)

    assert pool.totalAssets() == INIT_POOL_BALANCE - amount
    assert pool.totalSupply() == INIT_POOL_BALANCE - shares_withdrawn
    
    # TODO TEST when we re-implement withdraw fees
    if withdraw_fee > 0 and amount > FEE_COEFFICIENT:
        assert shares_withdrawn > amount

    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE - shares_withdrawn
    assert base_asset.balanceOf(me) == user_asset_balance + amount



@pytest.mark.ERC4626
@given(amount=st.integers(min_value=1, max_value=10**25),
        # total pool assets/shares to manipulate share price
        assets=st.integers(min_value=100, max_value=10**24),
        shares=st.integers(min_value=1, max_value=10**25),
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
        return # cant test bc redeem tx will revert
        
    pre_action_price = pool.price()
    assets_withdrawn = pool.redeem(amount, me, me, sender=me)
    
    # NOTE: MUST test events immediately after tx else boa deletes.
    logs = pool.get_logs()

    redeem_event = _find_event('Withdraw', logs)
    assert to_checksum_address(redeem_event.args_map['owner']) == me
    assert to_checksum_address(redeem_event.args_map['sender']) == me
    assert to_checksum_address(redeem_event.args_map['receiver']) == me
    assert redeem_event.args_map['assets'] == assets_withdrawn
    assert redeem_event.args_map['shares'] == amount

    redeem_rev_event = _find_event('RevenueGenerated', logs)
    assert redeem_rev_event.args_map['fee_type'] == 4
    assert redeem_rev_event.args_map['amount'] == amount
    assert redeem_rev_event.args_map['revenue'] == _calc_fee(shares=amount, fee=withdraw_fee, price=pre_action_price)
    assert to_checksum_address(redeem_rev_event.args_map['payer']) == me
    assert to_checksum_address(redeem_rev_event.args_map['token']) == pool.address
    assert to_checksum_address(redeem_rev_event.args_map['receiver']) == pool.address

    assert pool.totalAssets() == INIT_POOL_BALANCE - amount
    assert pool.totalSupply() == INIT_POOL_BALANCE - assets_withdrawn
    # assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE - amount # ensure shares burned from right person
    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE - amount
    assert base_asset.balanceOf(me) == user_asset_balance + assets_withdrawn
    
    # TODO TEST when we re-implement withdraw fees
    # burn more shares than amount even tho share price is 1
    if withdraw_fee == 0:
        assert pool.price() == POOL_PRICE_DECIMALS
    else:
        assert pool.price() >= POOL_PRICE_DECIMALS # TODO price will always be 0 if < 1:1 backing

    if withdraw_fee > 0 and amount > FEE_COEFFICIENT:
        min_amount_withdrawn = math.floor(amount + (amount * withdraw_fee / FEE_COEFFICIENT)) - 10
        assert assets_withdrawn < amount and assets_withdrawn <= min_amount_withdrawn



@pytest.mark.ERC4626
@given(amount=st.integers(min_value=1, max_value=10**25),
        # total pool assets/shares to manipulate share price
        assets=st.integers(min_value=100, max_value=10**24),
        shares=st.integers(min_value=1, max_value=10**25),
        withdraw_fee=st.integers(min_value=1, max_value=MAX_PITTANCE_FEE))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_redeem_with_approval(
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
        return # cant test bc redeem tx will revert
        
    pre_action_price = pool.price()
    assets_withdrawn = pool.redeem(amount, me, me, sender=me)
    
    # NOTE: MUST test events immediately after tx else boa deletes.
    logs = pool.get_logs()

    redeem_event = _find_event('Withdraw', logs)
    assert to_checksum_address(redeem_event.args_map['owner']) == me
    assert to_checksum_address(redeem_event.args_map['sender']) == me
    assert to_checksum_address(redeem_event.args_map['receiver']) == me
    assert redeem_event.args_map['assets'] == assets_withdrawn
    assert redeem_event.args_map['shares'] == amount

    redeem_rev_event = _find_event('RevenueGenerated', logs)
    assert redeem_rev_event.args_map['fee_type'] == 4
    assert redeem_rev_event.args_map['amount'] == amount
    assert redeem_rev_event.args_map['revenue'] == _calc_fee(shares=amount, fee=withdraw_fee, price=pre_action_price)
    assert to_checksum_address(redeem_rev_event.args_map['payer']) == me
    assert to_checksum_address(redeem_rev_event.args_map['token']) == pool.address
    assert to_checksum_address(redeem_rev_event.args_map['receiver']) == pool.address

    assert pool.totalAssets() == INIT_POOL_BALANCE - amount
    assert pool.totalSupply() == INIT_POOL_BALANCE - assets_withdrawn
    # assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE - amount # ensure shares burned from right person
    assert pool.balanceOf(me) == INIT_USER_POOL_BALANCE - amount
    assert base_asset.balanceOf(me) == user_asset_balance + assets_withdrawn
    
    # TODO TEST when we re-implement withdraw fees
    # burn more shares than amount even tho share price is 1
    if withdraw_fee == 0:
        assert pool.price() == POOL_PRICE_DECIMALS
    else:
        assert pool.price() >= POOL_PRICE_DECIMALS # TODO price will always be 0 if < 1:1 backing

    if withdraw_fee > 0 and amount > FEE_COEFFICIENT:
        min_amount_withdrawn = math.floor(amount + (amount * withdraw_fee / FEE_COEFFICIENT)) - 10
        assert assets_withdrawn < amount and assets_withdrawn <= min_amount_withdrawn


@pytest.mark.ERC4626
@given(amount=st.integers(min_value=1, max_value=10**35),)
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


@pytest.mark.slow
@pytest.mark.ERC4626
@pytest.mark.invariant
@given(shares=st.integers(min_value=100_000, max_value=10**35),
       assets=st.integers(min_value=100_000, max_value=10**35,))
@settings(max_examples=1000, deadline=timedelta(seconds=1000))
def test_invariant_preview_equals_virtual_share_price(pool, base_asset, me, admin, shares, assets):
    print(f"")
    pool.eval(f"self.total_assets = {assets}")
    pool.eval(f"self.total_supply = {shares}")
    pool.eval(f"self.balances[{me}] = {shares}")

    # price differential causes price calc to fail.
    # TODO found high/low bounds e.g. price cant be more than (1e12 * 10**DECIMALS) assets and cant be lower than (1e-8 * 10**DECIMALS)
    if abs(len(str(shares)) - len(str(assets * POOL_PRICE_DECIMALS))) > POOL_PRICE_DECIMALS:
        with boa.reverts():
            redeemable = pool.previewRedeem(shares)
        with boa.reverts():
            withdrawable = pool.previewWithdraw(assets)
        
    price = pool.price()
    print(f"share price {price} - {assets}/{shares}")
    redeemable = pool.previewRedeem(shares)
    withdrawable = pool.previewWithdraw(assets)
    expected_redeemable = _to_assets(shares, price)
    expected_withdrawable =  _to_shares(assets, price)
    print(f"assets back 4 shares - {redeemable}/{expected_redeemable}/{shares}")
    print(f"burn share 4 assets- {withdrawable}/{expected_withdrawable}/{assets}")
    assert redeemable == expected_redeemable
    assert withdrawable == expected_withdrawable

    mintable = pool.previewMint(shares)
    depositable = pool.previewDeposit(assets)
    expected_mintable =  _to_assets(min(MAX_UINT - pool.totalSupply(), shares), price)
    expected_depositable = _to_shares(min(assets, MAX_UINT  - pool.totalAssets()), price)
    print(f"assets deposited 4 shares - {mintable}/{expected_mintable}/{shares}")
    print(f"share received 4 assets- {depositable}/{expected_depositable}/{assets}")
    assert mintable == expected_mintable
    assert depositable == expected_depositable

    if assets > 0:
        pool.eval(f"self.total_deployed = {assets - 1}")
        redeemable = pool.previewRedeem(shares)
        withdrawable = pool.previewWithdraw(assets)
        # 4626 spec says dont account for user+global limits so dont account for liquid pool
        print(f"2 assets back 4 shares - {redeemable}/{expected_redeemable}/{shares}")
        print(f"2 burn share 4 assets- {withdrawable}/{expected_withdrawable}/{assets}")
        assert redeemable ==  expected_redeemable
        assert withdrawable == expected_withdrawable

    ## TODO TEST account for deposit/withdraw fees set fees to 0


@pytest.mark.slow
@pytest.mark.ERC4626
@pytest.mark.invariant
@given(shares=st.integers(min_value=1, max_value=10**35),
       assets=st.integers(min_value=100, max_value=10**35),
        pittance_fee=st.integers(min_value=1, max_value=MAX_PITTANCE_FEE),)
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_invariant_preview_equals_realized_share_price(
    pool, base_asset, me, admin,
    shares, assets, pittance_fee,
):
    """
    we do not take 
    """
    def reset(pool, asset):
        pool.eval(f"self.total_assets = {assets}")
        pool.eval(f"self.total_supply = {shares}")
        pool.eval(f"self.balances[{me}] = {shares}")
        asset.approve(pool, assets,  sender=me)
        # print("reset pool vals", pool.totalSupply(), pool.totalAssets())
    
    pre_action_price = pool.price()


    reset(pool, base_asset)
    redeemable = pool.previewRedeem(shares, sender=me)
    withdrawable = pool.previewWithdraw(assets, sender=me)
    print("reset pool vals", pool.totalSupply(), pool.totalAssets(), assets)
    redeemed = pool.redeem(shares, me, me, sender=me)
    reset(pool, base_asset)
    withdrawn = pool.withdraw(assets, me, me, sender=me)

    assert redeemable == redeemed
    assert withdrawable == withdrawn

    pool.eval(f"self.fees.withdraw = {pittance_fee}")

    withdraw_fee = _calc_fee(assets=assets, fee=withdraw_fee, price=pre_action_price)
    redeem_fee = _calc_fee(shares=shares, fee=withdraw_fee, price=pre_action_price)
    reset(pool, base_asset)
    redeemable= pool.previewRedeem(shares, sender=me)
    withdrawable = pool.previewWithdraw(assets, sender=me)
    print(f"preview price invariant - {shares}/{pool.totalSupply()}/")
    redeemed = pool.redeem(shares, me, me, sender=me)
    reset(pool, base_asset)
    withdrawn = pool.withdraw(assets, me, me, sender=me)
    reset(pool, base_asset)

    assert redeemable == redeemed
    assert withdrawable == withdrawn


    reset(pool, base_asset)
    mintable = pool.previewMint(shares, sender=me)
    depositable = pool.previewDeposit(assets, sender=me)
    minted = pool.mint(shares, me, sender=me)
    reset(pool, base_asset)
    deposited = pool.deposit(assets, me, sender=me)
    reset(pool, base_asset)
    assert mintable == minted
    assert depositable == deposited
    
    pool.eval(f"self.fees.deposit = {pittance_fee}")

    reset(pool, base_asset)
    mintable = pool.previewMint(shares, sender=me)
    depositable = pool.previewDeposit(assets, sender=me)
    minted = pool.mint(shares, me, sender=me)
    reset(pool, base_asset)
    deposited = pool.deposit(assets, me, sender=me)
    reset(pool, base_asset)
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
@pytest.mark.invariant
@given(assets=st.integers(min_value=100, max_value=10**35),)
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