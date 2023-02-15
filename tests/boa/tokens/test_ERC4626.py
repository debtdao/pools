import boa
import ape
import pytest
import math
import logging
from datetime import timedelta
from hypothesis import given, settings
from hypothesis import strategies as st

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
    assert pool.total_assets() == init_token_balances * 2
    # 1:1 initial backing
    assert pool.totalSupply() == pool.total_assets()
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

    # test event emissions
    # TODO python bug on get_logs(). `Error: cant cast to Int`
    # logs = pool.get_logs()
    # print(logs) 

    # # expected_shares = round(amount / share_price)
    # expected_shares = math.floor(amount / share_price)
    # # ensure right price for shares
    # # accomodate evm vs python rounding differences
    # _assert_uint_with_rounding(shares_created, expected_shares)
    # # ensure shares got minted to right person
    # _assert_uint_with_rounding(pool.balanceOf(me), expected_shares)
    # # ensure supply was inflated by deposit + fee
    # expected_total_supply = shares + shares_created + fees_generated
    # _assert_uint_with_rounding(pool.totalSupply(), expected_total_supply)

@pytest.mark.ERC4626
@given(amount=st.integers(min_value=0, max_value=(MAX_UINT / 4) * 3),)
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_deposit_cant_cause_total_asset_overflow(pool, base_asset, me, admin, init_token_balances, amount):
    init_pool_deposits = init_token_balances * 2
    max_avail = min(amount, MAX_UINT - init_pool_deposits)
    
    assert pool.total_assets() == init_pool_deposits # ensure clean state
    base_asset.mint(me, max_avail, sender=me) # do + 1 to test max overflow
    base_asset.approve(pool, max_avail, sender=me)
    pool.deposit(max_avail, me, sender=me)
    assert pool.total_assets() == init_pool_deposits + max_avail # ensure clean state

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

# preview functions - right share price return value
# preview functions - proper fees calculated
# preview -> action equality
# mint/redeem + deposit/withdraw equality (incl fees)

# TEST all events properly emitted 
# deposit/withdraw


# TEST invariants
# total supply with mint/burn


# https://github.com/fubuloubu/ERC4626/blob/main/tests/test_methods.py

ROUNDING_ERROR = 10*8
def _assert_uint_with_rounding(target_num, my_num):
    assert my_num - ROUNDING_ERROR <= target_num <= my_num + ROUNDING_ERROR