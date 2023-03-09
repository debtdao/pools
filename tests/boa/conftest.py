import ape
import boa
import math
import pytest
import logging

from eip712.messages import EIP712Message

boa.interpret.set_cache_dir()
boa.reset_env()
logging.basicConfig(format='%(asctime)s - %(message)s', level=logging.INFO)

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
MAX_UINT = 115792089237316195423570985008687907853269984665640564039457584007913129639935
INIT_POOL_BALANCE =  10**25  # 1M @ 18 decimals
INIT_USER_POOL_BALANCE = 5*10**24
POOL_PRICE_DECIMALS=1e18

# dummy addresses. not active signers like Ape.accounts
@pytest.fixture(scope="module")
def me():
    return boa.env.generate_address()

@pytest.fixture(scope="module")
def admin():
    return boa.env.generate_address()

@pytest.fixture(scope="module")
def treasury():
    return boa.env.generate_address()

@pytest.fixture(scope="module")
def base_asset(admin):
    with boa.env.prank(admin): # necessary?
        return boa.load('tests/mocks/MockERC20.vy', "Lending Token", "LEND", 18)

# @pytest.fixture(scope="module")
# def bond_token(admin):
#     with boa.env.prank(admin): # necessary?
#         return boa.load('contracts/BondToken.vy', "Bondage Token", "BONDAGE", 18, admin)

@pytest.fixture(scope="module")
def pool(admin, base_asset):
    with boa.env.prank(admin): # necessary?
        return boa.load('contracts/DebtDAOPool.vy', admin, base_asset, "Dev Testing", "KIBA-TEST", [ 0, 0, 0, 0, 0, 0 ])

@pytest.fixture(scope="module")
def all_erc20_tokens(base_asset, pool):
    return [base_asset, pool]


@pytest.fixture(scope="module")
def all_erc4626_tokens(pool):
    return [pool]

@pytest.fixture(scope="module")
def _deposit(pool, base_asset):
    def deposit(amount, receiver, referrer=None):
        base_asset.mint(receiver, amount)
        base_asset.approve(pool, amount, sender=receiver)
        if referrer:
            return pool.depositWithReferral(amount, receiver, referrer, sender=receiver)
        else:
            return pool.deposit(amount, receiver, sender=receiver)
    return deposit


@pytest.fixture(scope="module")
def init_token_balances(base_asset, pool, admin, me):
    # TODO dont be an idiot and use boa.eval instead of contract calls

    # mock token
    base_asset.mint(me, INIT_USER_POOL_BALANCE)
    base_asset.mint(admin, INIT_USER_POOL_BALANCE)

    # mint lending tokens then deposit into pool to get
    base_asset.mint(me, INIT_USER_POOL_BALANCE, sender=me)
    base_asset.approve(pool, INIT_USER_POOL_BALANCE, sender=me)
    shares = pool.deposit(INIT_USER_POOL_BALANCE, me, sender=me)

    base_asset.mint(admin, INIT_USER_POOL_BALANCE, sender=admin)
    base_asset.approve(pool, INIT_USER_POOL_BALANCE, sender=admin)
    shares2 = pool.deposit(INIT_USER_POOL_BALANCE, admin, sender=admin)

    assert shares == INIT_USER_POOL_BALANCE # shares should be 1:1
    assert shares == shares2     # share price shouldnt change

    return INIT_USER_POOL_BALANCE

# @pytest.fixture(scope="module")
# def Permit(chain, token):
#     class Permit(EIP712Message):
#         _name_  = "Lending Token" #: "string"
#         _version_  ="1.0" #: "string"
#         _chainId_  = chain.chain_id #: "uint256"
#         _verifyingContract_  = token.address #: "address"

#         # owner  : "address"
#         # spender  : "address"
#         # value  : "uint256"
#         # nonce  : "uint256"
#         # deadline  : "uint256"

#     return Permit

# @pytest.fixture(scope="module")
# def collateral_token(admin):
#     with boa.env.prank(admin):
#         return boa.load('contracts/testing/ERC20Mock.vy', "Collateral", "ETH", 18)


# @pytest.fixture(scope="module")
# def price_oracle(admin):
#     with boa.env.prank(admin):
#         oracle = boa.load('contracts/testing/DummyPriceOracle.vy', admin, PRICE * 10**18)
#         return oracle