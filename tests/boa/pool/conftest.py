import boa
import logging
import pytest
from eth_utils import to_checksum_address
from ..conftest import MAX_UINT, ZERO_ADDRESS
from ..utils.events import _find_event, _find_event_by
from boa.vyper.event import Event

VESTING_RATE_COEFFICIENT = 10**18
FEE_COEFFICIENT = 10000 # 100% in bps
MAX_PITTANCE_FEE = 200 # 2% in bps
SET_FEES_TO_ZERO = "self.fees = Fees({performance: 0, deposit: 0, withdraw: 0, flash: 0, collector: 0, referral: 0})"
NULL_POSITION = f"Position({{deposit: 0, principal: 0, interestAccrued: 0, interestRepaid: 0, decimals: 0, token: {ZERO_ADDRESS}, lender: {ZERO_ADDRESS}, isOpen: True}})"
ONE_YEAR_IN_SEC=60*60*24*365.25
INTEREST_TIMESPAN_SEC = int(ONE_YEAR_IN_SEC / 12)
DRATE=2000
FRATE=1000

boa.interpret.set_cache_dir()
boa.reset_env()

@pytest.fixture(scope="module")
def borrower():
    return boa.env.generate_address()

@pytest.fixture(scope="module")
def mock_line(_create_line, borrower):
    return _create_line(borrower)

@pytest.fixture(scope="module")
def vault(me, base_asset):
    with boa.env.prank(me): # necessary?
        return boa.load('contracts/DebtDAOPool.vy', me, base_asset, "HYYYUUGE PROFIT MOBILE", "HYYUU", [ 2000, 100, 100, 10, 100, 200 ])


@pytest.fixture(scope="module")
def my_line(_create_line, me):
    return _create_line(me)

@pytest.fixture(scope="module")
def flash_borrower(_create_line, me):
    return boa.load("tests/mocks/FlashBorrower.vy")


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
def _compute_id(mock_line):
    def compute_id(lender, token, line=mock_line):
        return line.computeId(lender, token)
    return compute_id


@pytest.fixture(scope="module")
def _add_credit(pool, mock_line, base_asset, admin, me, _deposit):
    def add_credit(amount, drate=0, frate=0, line=mock_line, new_deposit=True):
        if new_deposit:
            _deposit(amount, me)
        id = pool.add_credit(line, drate, frate, amount, sender=pool.owner())
        return id
    return add_credit

@pytest.fixture(scope="module")
def _increase_credit(pool, mock_line, base_asset, admin, me, _deposit, _compute_id):
    def increase_credit(amount, drate=0, frate=0, line=mock_line, new_deposit=True):
        if new_deposit:
            _deposit(amount, admin)
        pool.increase_credit(line, _compute_id(pool, base_asset, line), amount, sender=pool.owner())
        return id
    return increase_credit


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
    def repay(line, id, amount, payer=me, close=False):
        base_asset.mint(payer, amount)
        base_asset.approve(line, amount, sender=payer)

        if close and amount == MAX_UINT:
            line.depositAndClose(sender=payer)
        elif close:
            line.close(sender=payer)
        else:
            line.depositAndRepay(id, amount, sender=payer)

    return repay


@pytest.fixture(scope="module")
def _collect_interest(pool, mock_line, base_asset, admin, flash_borrower, _add_credit, _repay, _get_position):
    def collect_interest(amount, drate, frate, timespan, line=mock_line, id=None):
        if not id:
            id = _add_credit(amount, drate, frate, line)
        boa.env.time_travel(seconds=timespan)
        line.accrueInterest(id)
        interest_earned = _get_position(line, id)['interestAccrued']
        if interest_earned > 0:
            _repay(line, id, interest_earned)
            pool.collect_interest(line, id, sender=flash_borrower.address)
        return interest_earned, id

    return collect_interest



@pytest.fixture(scope="module")
def _gen_rev(pool, base_asset, flash_borrower, _deposit, _collect_interest, me) -> Event | None:
    def gen_rev(fee_type, amount):
        """
        @return - [fee_type, amount_generated]
        """
        # print(f"generate revenue helper type/event  :  {fee_type}")
        match fee_type:
            case 'performance':
                interest, id = _collect_interest(amount, DRATE, FRATE, INTEREST_TIMESPAN_SEC)
                # print("performance fee", interest, id)
                return {
                    'event': _find_event_by({ "fee_type": 1 }, pool.get_logs()),
                    'position_id': id,
                    'interest': interest,
                }
            case 'deposit':
                shares = _deposit(amount, me)
                # print("deposit fee", 0)
                return {
                    'event': _find_event_by({ "fee_type": 2 }, pool.get_logs()),
                    'shares': shares,
                }
            case 'withdraw':
                _deposit(amount, me)
                shares = pool.withdraw(amount, me, me, sender=me)
                # print("withdraw fee", 0)
                return {
                    'event': _find_event_by({ "fee_type": 4 }, pool.get_logs()),
                    'shares': shares,
                }
            case 'flash':
                pool.flashLoan(flash_borrower, base_asset, amount, "")
                # print("flash fee", 0)
                return {
                    'event': _find_event_by({ "fee_type": 8 }, pool.get_logs()),
                }
            case 'collector':
                interest, id = _collect_interest(amount, DRATE, FRATE, INTEREST_TIMESPAN_SEC)
                # print("performancefee", 0)
                return {
                    'event': _find_event_by({ "fee_type": 1 }, pool.get_logs()),
                    'position_id': id,
                    'interest': interest,
                }
            case 'referral':
                shares = _deposit(amount, me, flash_borrower) #random referrer
                # print("referral fee", 0)
                return {
                    'event': _find_event_by({ "fee_type": 32 }, pool.get_logs()),
                    'shares': shares,
                }
            case 'snitch':
                # TODO generate snitch fees
                 return {
                    'event':  _find_event_by({ "fee_type": 64 }, pool.get_logs()),
                }

    return gen_rev


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