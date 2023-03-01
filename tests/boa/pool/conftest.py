import boa
import logging
import pytest
from eth_utils import to_checksum_address
from ..conftest import MAX_UINT
from ..utils.events import _find_event, _find_event_by
from boa.vyper.event import Event

VESTING_RATE_COEFFICIENT = 10**18
SET_FEES_TO_ZERO = "self.fees = Fees({performance: 0, deposit: 0, withdraw: 0, flash: 0, collector: 0, referral: 0})"
ONE_YEAR_IN_SEC=60*60*24*365.25
INTEREST_TIMESPAN_SEC = int(ONE_YEAR_IN_SEC / 12)

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


@pytest.fixture(scope="module")
def _collect_interest(pool, mock_line, base_asset, admin, me, _add_credit, _repay, _get_position):
    def collect_interest(amount, drate, frate, timespan, line=mock_line):
        id = _add_credit(amount, drate, frate, line)
        boa.env.time_travel(timespan)
        interest_earned = _get_position(line, id)['interestAccrued']
        owed = amount + interest_earned
        _repay(id, owed)
        pool.reduce_credit(line, id, MAX_UINT, sender=admin) # return principal + interest back to pool
        return interest_earned
        
    return collect_interest



@pytest.fixture(scope="module")
def _gen_rev(pool, base_asset, flash_borrower, _deposit, _collect_interest, me) -> Event | None:
    def gen_rev(fee_type, amount):
        """
        @return - [fee_type, amount_generated]
        """
        print(f"generate revenue helper type/event  :  {fee_type}")
        event = None
        match fee_type:
            case 'performance':
                _collect_interest(amount, 2000, 1000, INTEREST_TIMESPAN_SEC)
                # print("performancefee", 0)
                event = _find_event_by({ "fee_type": 1 }, pool.get_logs())
            case 'deposit':
                shares = _deposit(amount, me)
                # print("deposit fee", 0)
                event = _find_event_by({ "fee_type": 2 }, pool.get_logs())
            case 'withdraw':
                _deposit(amount, me) 
                pool.withdraw(amount, me, me, sender=me)
                # print("withdraw fee", 0)
                event = _find_event_by({ "fee_type": 4 }, pool.get_logs())
            case 'flash':
                _deposit(amount, me) 
                # pool.flashLoan(flash_borrower, base_asset, amount, "")
                # print("flash fee", 0)
                event = _find_event_by({ "fee_type": 8 }, pool.get_logs())
            case 'collector':
                _collect_interest(amount, 2000, 1000, INTEREST_TIMESPAN_SEC)
                # print("collector fee", 0)
                event = _find_event_by({ "fee_type": 16 }, pool.get_logs())
            case 'referral':
                _deposit(amount, me)
                # print("referral fee", 0)
                event = _find_event_by({ "fee_type": 32 }, pool.get_logs())
            case 'snitch':
                _deposit(amount, me)
                # print("snitch fee", 0)
                event = _find_event_by({ "fee_type": 64 }, pool.get_logs())

        # print(f"generate revenue helper type/event  :  {fee_type}={event}")
        return event.args_map if event != None else None

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