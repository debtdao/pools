import boa
import pytest

boa.interpret.set_cache_dir()
boa.reset_env()


PRICE = 3000

@pytest.fixture(scope="module")
def accounts():
    return [boa.env.generate_address() for i in range(10)]


@pytest.fixture(scope="module")
def admin():
    return boa.env.generate_address()

@pytest.fixture(scope="module")
def lending_token(admin):
    with boa.env.prank(admin):
        return boa.load('./tests/mocks/MockERC20.vy', "Lending Token", "LEND", 18)


# @pytest.fixture(scope="module")
# def collateral_token(admin):
#     with boa.env.prank(admin):
#         return boa.load('contracts/testing/ERC20Mock.vy', "Collateral", "ETH", 18)


@pytest.fixture(scope="module")
def price_oracle(admin):
    with boa.env.prank(admin):
        oracle = boa.load('contracts/testing/DummyPriceOracle.vy', admin, PRICE * 10**18)
        return oracle