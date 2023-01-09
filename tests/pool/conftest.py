# import boa
# import pytest

# boa.interpret.set_cache_dir()
# boa.reset_env()


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