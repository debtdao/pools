import boa
import pytest

# boa.interpret.set_cache_dir()
# boa.reset_env()

@pytest.fixture(scope="session")
def borrower():
    return boa.env.generate_address()

@pytest.fixture(scope="session")
def pool_roles():
    return ['owner', 'rev_recipient']

@pytest.fixture(scope="session")
def pool_fee_types():
    return [
    	# NOTE: MUST be same order as Fees enum
        'performance',
        'deposit',
        'withdraw',
        'flash',
        'collector',
        'referral',
        # 'snitch', unique constant fee, we test separately
    ]

@pytest.fixture(scope="session")
def pittance_fee_types(pool_fee_types):
    return pool_fee_types[1:] # cut performance and snitch fees of ends

# @pytest.fixture(scope="session")
# def line(pool, admin, borrower):
        # TODO make mock line contract for investing/impairment
#     return boa.load('contracts/MockLine.vy', borrower, admin)

# @pytest.fixture(scope="session")
# def pool(admin, asset_token):
#     # deploy a pool contract and connect it
#     return boa.load('contracts/PoolDelegate.vy', admin, asset_token, "Test", "TEST", {
#         'performance': '1000',
#         'deposit': '0',
#         'withdraw': '0',
#         'flash': '15',
#         'collector': '100',
#         'referral': '50',
#     })