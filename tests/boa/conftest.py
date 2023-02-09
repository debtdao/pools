import ape
import boa
import pytest
from eip712.messages import EIP712Message

boa.interpret.set_cache_dir()
boa.reset_env()

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
MAX_UINT = 115792089237316195423570985008687907853269984665640564039457584007913129639935

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
        print(ape.types)
        return boa.load('contracts/DebtDAOPool.vy', admin, base_asset, "Dev Testing", "KIBA-TEST", [ 0, 0, 0, 0, 0, 0 ])

@pytest.fixture(scope="module")
def all_erc20_tokens(base_asset, pool):
    return [base_asset, pool]


@pytest.fixture(scope="module")
def all_erc4626_tokens(pool):
    return [pool]

@pytest.fixture(scope="module")
def init_token_balances(base_asset, pool, admin, me):
    mint_amount = 10**25  # 1M @ 18 decimals

    # TODO dont be an idiot and use boa.eval instead of contract calls

    # mock token
    base_asset.mint(me, mint_amount)
    base_asset.mint(admin, mint_amount)

    # mint lending tokens then deposit into pool to get
    base_asset.mint(me, mint_amount, sender=me)
    base_asset.approve(pool, mint_amount, sender=me)
    shares = pool.deposit(mint_amount, me, sender=me)
        
    base_asset.mint(admin, mint_amount, sender=admin)
    base_asset.approve(pool, mint_amount, sender=admin)
    shares2 = pool.deposit(mint_amount, admin, sender=admin)

    assert shares == mint_amount # shares should be 1:1
    assert shares == shares2     # share price shouldnt change

    return mint_amount

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