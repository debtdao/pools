import ape
import boa
import pytest
from eip712.messages import EIP712Message

boa.interpret.set_cache_dir()
boa.reset_env()


PRICE = 3000
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
def lending_token(admin):
    with boa.env.prank(admin): # necessary?
        return boa.load('tests/mocks/MockERC20.vy', "Lending Token", "LEND", 18)

@pytest.fixture(scope="module")
def bond_token(admin):
    with boa.env.prank(admin): # necessary?
        return boa.load('contracts/BondToken.vy', "Bondage Token", "BONDAGE", 18, admin)

@pytest.fixture(scope="module")
def pool_token(admin, lending_token):
    with boa.env.prank(admin): # necessary?
        print(ape.types)
        return boa.load('contracts/PoolDelegate.vy', admin, lending_token, "Dev Testing", "KIBA-TEST", [ 0, 0, 0, 0, 0, 0 ])

@pytest.fixture(scope="module")
def all_erc20_tokens(lending_token, pool_token, bond_token):
    return [lending_token, pool_token, bond_token]


@pytest.fixture(scope="module")
def all_erc4626_tokens(pool_token):
    return [pool_token]

@pytest.fixture(scope="module")
def init_token_balances(lending_token, bond_token, pool_token, admin, me):
    mint_amount = 10**25  # 1M @ 18 decimals

    # TODO dont be an idiot and use boa.eval instead of contract calls

    # mock token
    lending_token._mint_for_testing(me, mint_amount)
    lending_token._mint_for_testing(admin, mint_amount)

    bond_token.mint(me, mint_amount, sender=admin)
    bond_token.mint(admin, mint_amount, sender=admin)

    # mint lending tokens then deposit into pool to get
    lending_token._mint_for_testing(me, mint_amount, sender=me)
    lending_token.approve(pool_token, mint_amount, sender=me)
    shares = pool_token.deposit(mint_amount, me, sender=me)
        
    lending_token._mint_for_testing(admin, mint_amount, sender=admin)
    lending_token.approve(pool_token, mint_amount, sender=admin)
    shares2 = pool_token.deposit(mint_amount, admin, sender=admin)

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