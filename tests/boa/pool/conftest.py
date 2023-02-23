import boa
import pytest
from eth_utils import to_checksum_address
from ..conftest import MAX_UINT

VESTING_RATE_COEFFICIENT = 10**18
SET_FEES_TO_ZERO = "self.fees = Fees({performance: 0, deposit: 0, withdraw: 0, flash: 0, collector: 0, referral: 0})"

boa.interpret.set_cache_dir()
boa.reset_env()

@pytest.fixture(scope="module")
def borrower():
    return boa.env.generate_address()

@pytest.fixture(scope="module")
def mock_line(_create_line, borrower):
    return _create_line(borrower)

@pytest.fixture(scope="module")
def my_line(_create_line, me):
    return _create_line(me)

@pytest.fixture(scope="module")
def pool_roles():
    return ['owner', 'rev_recipient']

@pytest.fixture(scope="module")
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

@pytest.fixture(scope="module")
def pittance_fee_types(pool_fee_types):
    return pool_fee_types[1:] # cut performance and snitch fees of ends

###########
# Higher Order Function Helper Fixtures
# have to do this weird thing bc cant call functions directly when importing as fixtures
###########


@pytest.fixture(scope="module")
def _create_line():
    def deploy(borrower):
         return boa.load("tests/mocks/MockLine.vy", borrower)
    return deploy


@pytest.fixture(scope="module")
def _deposit(pool, mock_line, base_asset):
    def deposit(amount, receiver):
        base_asset.mint(receiver, amount)
        base_asset.approve(pool, amount, sender=receiver)
        pool.deposit(amount, receiver, sender=receiver)
    return deposit

@pytest.fixture(scope="module")
def _add_credit(pool, mock_line, base_asset, admin, me, _deposit):
    def add_credit(amount, drate=0, frate=0, line=mock_line, new_deposit=True):
        if new_deposit:
            _deposit(amount, me)
        id = pool.add_credit(line, drate, frate, amount, sender=pool.owner())
        return id
    return add_credit

@pytest.fixture(scope="module")
def _get_position():
    def get_position(line, id):
        (deposit, principal, interestAccrued, intersetRepaid, decimals, token, lender, isOpen) = line.credits(id)
        return {
            'deposit': deposit,
            'principal': principal,
            'interestAccrued': interestAccrued,
            'interestRepaid': intersetRepaid,
            'decimals': decimals,
            'token': to_checksum_address(token),
            'lender': to_checksum_address(lender),
            'isOpen': isOpen,
        }
    return get_position

@pytest.fixture(scope="module")
def _repay(mock_line, base_asset, me):
    def repay(id, amount, payer=me, close=False):
        base_asset.mint(payer, amount)
        base_asset.approve(mock_line, amount, sender=payer)

        if close and amount == MAX_UINT:
            mock_line.depositAndClose(sender=payer)
        elif close:
            mock_line.close(sender=payer)
        else:
            mock_line.depositAndRepay(id, amount, sender=payer)
        
    return repay



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