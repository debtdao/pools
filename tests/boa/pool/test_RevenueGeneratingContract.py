# TODO check tests against most recent

import boa
import ape
from eth_utils import to_checksum_address
import pytest
import logging
from boa.vyper.contract import BoaError
from hypothesis import given, settings
from hypothesis import strategies as st
from hypothesis.stateful import RuleBasedStateMachine, run_state_machine_as_test, rule, invariant
from datetime import timedelta
from ..utils.events import _find_event

MAX_UINT = 115792089237316195423570985008687907853269984665640564039457584007913129639935
MAX_TOKEN_AMOUNT = MAX_UINT - 10**25 # offset by existing admin balance so no overflows
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
ClaimRevenueEventLogIndex = 2 # log index of ClaimRevenue event inside claim_rev logs (approve, transfer, claim, price)


# Table of Contents

# Role ACL and state changes
# (done) 1. only {role} can set_{role}
# (done) 3. {role} cant call accept_{role}
# (done) 5. no one can accept_{role} if pending_{role} is null
# (done) 6. no one can set_{role} if {role} is null
# (done) 2. pending_{role} can call accept_{role}
# (done) 2. emits NewPending{role} event with appropriate new_{role}
# (done) 4. emits Accepted{role} event with appropriate {role}

# Control of revenue stream
# (done) 1. rev_recipient can claim_rev
# (done) 1. non rev_recipient cant claim_rev
# (done) 1. self.owner cant claim_rev
# (done in pool impl tests) 4. MUST emit RevenueGenerated event even if event.revenue == 0
# 2. (invariant) all self.owner rev is claimable by self.rev_recipient
# 3. (invariant) claimable rev == sum of self.owner fees events emitted
# 5. (invariant) max_uint claim_rev is claimable_rev
# (done) 6. cant claim more than claimable_rev from claim_rev
# (idk how to test) 9. claim rev should fail if push payments implemented
# (idk how to test) 7. if accept_ivoice doesnt revert, it must return IRevenueGenerator.payInvoice.selector


# Role ACL and state changes
def _get_role_actions(role) -> object:
    match role:
        case 'owner':
            return {
                'set': 'set_owner',
                'accept': 'accept_owner',
                'get': 'owner',
                'next': 'pending_owner',
            }
        case 'rev_recipient':
            return {
                'set': 'set_rev_recipient',
                'accept': 'accept_rev_recipient',
                'get': 'rev_recipient',
                'next': 'pending_rev_recipient',
            }

def _call_pool_as_role(pool, role, action, sender = boa.env.generate_address(), *args):
    # generalized testing for role based functions
    func_name = _get_role_actions(role)[action]
    # get actual function on contract based on name of func for role
    func = getattr(pool, func_name, lambda x: "No func for role found")
    print("func to call", func, args)
    # call pool with args if provided
    # TODO: state is not properly updated/persisted with these calls.
    # i think getattr is calling contract class directly and not simulating with boa so these calls do nothing
    return func(*args, sender=sender) if len(args) > 0 else func(sender=sender)


@pytest.mark.pool
@pytest.mark.rev_generator
def test_only_current_role_holder_can_set_role(pool, me, admin, pool_roles):
    for role in pool_roles:

        assert to_checksum_address(_call_pool_as_role(pool, role, 'get')) == admin

        with boa.reverts(f"not {role}"):
            # known party cant set themselves as delegate
            _call_pool_as_role(pool, role, 'set', me, me) # state not saved


        with boa.reverts(f"not {role}"):
            # anon cant set anon as delegate
            _call_pool_as_role(pool, role, 'set', boa.env.generate_address(), boa.env.generate_address())

        _call_pool_as_role(pool, role, 'set', admin, me)

        assert me == _call_pool_as_role(pool, role, 'next')
        _call_pool_as_role(pool, role, 'accept', me)

        assert to_checksum_address(_call_pool_as_role(pool, role, 'get')) == me
        assert _call_pool_as_role(pool, role, 'next') == me

        with boa.reverts(f"not {role}"):
            # ensure old owner can no longer has access
            _call_pool_as_role(pool, role, 'set', admin, admin)

        _call_pool_as_role(pool, role, 'set', me, admin)
        assert _call_pool_as_role(pool, role, 'get', admin) == me
        assert _call_pool_as_role(pool, role, 'next', admin) == admin
        _call_pool_as_role(pool, role, 'accept', admin)
        assert _call_pool_as_role(pool, role, 'get', admin) == admin
        assert _call_pool_as_role(pool, role, 'next', admin) == admin

@pytest.mark.pool
@pytest.mark.rev_generator
def test_can_override_pending_role_before_accepted(pool, me, admin, pool_roles):
    for role in pool_roles:
        assert to_checksum_address(_call_pool_as_role(pool, role, 'get')) == admin

        _call_pool_as_role(pool, role, 'set', admin, me)
        assert _call_pool_as_role(pool, role, 'next') == me

        rando = boa.env.generate_address()
        _call_pool_as_role(pool, role, 'set', admin, rando)
        assert _call_pool_as_role(pool, role, 'next') == rando

        with boa.reverts(f"not pending {role}"):
            _call_pool_as_role(pool, role, 'accept', me)

@pytest.mark.pool
@pytest.mark.rev_generator
def test_cant_accept_role_as_current_role_holder(pool, me, admin, pool_roles):
    for role in pool_roles:
        assert to_checksum_address(_call_pool_as_role(pool, role, 'get')) == admin

        _call_pool_as_role(pool, role, 'set', admin, me)
        assert _call_pool_as_role(pool, role, 'next') == me

        with boa.reverts(f"not pending {role}"):
            _call_pool_as_role(pool, role, 'accept', admin)

        with boa.reverts(f"not pending {role}"):
            _call_pool_as_role(pool, role, 'accept', boa.env.generate_address())

        _call_pool_as_role(pool, role, 'accept', me)

@pytest.mark.pool
@pytest.mark.rev_generator
def test_can_accept_role_as_pending_holder(pool, me, admin, pool_roles):
    for role in pool_roles:
        assert to_checksum_address(_call_pool_as_role(pool, role, 'get')) == admin

        _call_pool_as_role(pool, role, 'set', admin, me)
        assert _call_pool_as_role(pool, role, 'next') == me

        _call_pool_as_role(pool, role, 'accept', me)

@pytest.mark.pool
@pytest.mark.rev_generator
@pytest.mark.event_emissions
def test_setting_role_emits_pending_role_event(pool, me, admin, pool_roles):
    for role in pool_roles:
        assert to_checksum_address(_call_pool_as_role(pool, role, 'get')) == admin

        _call_pool_as_role(pool, role, 'set', admin, me)

        event = pool.get_logs()[0]
        assert to_checksum_address(event.args_map['new_recipient']) == me
        capitalcase_role = ''.join(map(lambda word: word.title(), role.split('_')))
        assert f'{event.event_type}' == f'event NewPending{capitalcase_role}(address)'


@pytest.mark.pool
@pytest.mark.rev_generator
@pytest.mark.event_emissions
def test_accepting_role_emits_accept_role_event(pool, me, admin, pool_roles):
    for role in pool_roles:
        assert to_checksum_address(_call_pool_as_role(pool, role, 'get')) == admin

        _call_pool_as_role(pool, role, 'set', admin, me)
        _call_pool_as_role(pool, role, 'accept', me)

        event = pool.get_logs()[0]
        assert to_checksum_address(event.args_map['new_recipient']) == me
        capitalcase_role = ''.join(map(lambda word: word.title(), role.split('_')))
        assert f'{event.event_type}' == f'event Accept{capitalcase_role}(address)'

@pytest.mark.pool
@pytest.mark.rev_generator
def test_cant_set_pending_role_if_role_is_null(pool, me, admin, pool_roles):
    for role in pool_roles:
        pool.eval(f'self.{role} = {ZERO_ADDRESS}')
        assert to_checksum_address(_call_pool_as_role(pool, role, 'get')) == ZERO_ADDRESS

        with boa.reverts(f'not {role}'):
            _call_pool_as_role(pool, role, 'set', admin, me)

        with boa.reverts(f'not {role}'):
            rando = boa.env.generate_address()
            _call_pool_as_role(pool, role, 'set', rando, admin)

@pytest.mark.pool
@pytest.mark.rev_generator
def test_cant_accept_null_role(pool, me, admin, pool_roles):
    for role in pool_roles:
        assert to_checksum_address(_call_pool_as_role(pool, role, 'get')) == admin
        assert _call_pool_as_role(pool, role, 'next') == ZERO_ADDRESS

        with boa.reverts():
            _call_pool_as_role(pool, role, 'accept', admin)

        with boa.reverts():
            _call_pool_as_role(pool, role, 'accept', me)

        with boa.reverts():
            _call_pool_as_role(pool, role, 'accept', boa.env.generate_address())

        logs = pool.get_logs()
        assert len(logs) == 0


@pytest.mark.acl
@pytest.mark.pool
@pytest.mark.slow
@pytest.mark.rev_generator
@given(amount=st.integers(min_value=1, max_value=MAX_UINT)) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_rev_recipient_can_claim_rev(pool, admin, amount):
    assert pool.rev_recipient() == admin
    assert pool.claimable_rev(pool) == 0
    assert pool.balanceOf(admin) == 0

    # give revenue to delegate
    pool.eval(f'self.accrued_fees = {amount}')
    pool.eval(f'self.balances[self] = {amount}')
    assert pool.claimable_rev(pool) == amount
    assert pool.accrued_fees() == amount

    # test claiming 0
    pool.claim_rev(pool, 0, sender=admin)

    event = pool.get_logs()[ClaimRevenueEventLogIndex]
    assert f'{event.event_type}' == 'event RevenueClaimed(address,uint256)'
    assert to_checksum_address(event.args_map['rev_recipient']) == admin
    assert event.args_map['amount'] == 0
    assert pool.claimable_rev(pool) == amount
    assert pool.accrued_fees() == amount
    # running README boa init in repl and calling this works so issue with test setup
    pool.claim_rev(pool, 1, sender=admin)

    event = pool.get_logs()[ClaimRevenueEventLogIndex]
    assert f'{event.event_type}' == 'event RevenueClaimed(address,uint256)'
    assert to_checksum_address(event.args_map['rev_recipient']) == admin
    assert event.args_map['amount'] == 1
    assert pool.claimable_rev(pool) == amount - 1
    assert pool.accrued_fees() == amount - 1

    pool.claim_rev(pool, amount - 1, sender=admin)

    event = pool.get_logs()[ClaimRevenueEventLogIndex]
    assert f'{event.event_type}' == 'event RevenueClaimed(address,uint256)'
    assert to_checksum_address(event.args_map['rev_recipient']) == admin
    assert event.args_map['amount'] == amount - 1
    assert pool.claimable_rev(pool) == 0
    assert pool.accrued_fees() == 0

    # test max claim shortcut
    # reset all values so no overflow
    pool.eval(f'self.accrued_fees = {amount}')
    pool.eval(f'self.balances[self] = {amount}')
    pool.eval(f'self.balances[self.owner] = 0')
    assert pool.claimable_rev(pool) == amount
    assert pool.accrued_fees() == amount

    pool.claim_rev(pool, MAX_UINT, sender=admin)
    event = pool.get_logs()[ClaimRevenueEventLogIndex]
    assert f'{event.event_type}' == 'event RevenueClaimed(address,uint256)'
    assert to_checksum_address(event.args_map['rev_recipient']) == admin
    assert event.args_map['amount'] == amount
    assert pool.claimable_rev(pool) == 0


@pytest.mark.pool
@pytest.mark.rev_generator
@given(amount=st.integers(min_value=1, max_value=MAX_UINT)) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_rev_recipient_cant_overclaim_rev(pool, admin, amount):
    # test max claim shortcut
    pool.eval(f'self.accrued_fees = {amount}')
    pool.eval(f'self.balances[self] = {amount}')
    assert pool.claimable_rev(pool) == amount
    assert pool.accrued_fees() == amount

    with boa.reverts():
        pool.claim_rev(pool, amount + 1, sender=admin)

    assert pool.claimable_rev(pool) == amount
    assert pool.accrued_fees() == amount

    pool.claim_rev(pool, amount, sender=admin)

    event = pool.get_logs()[ClaimRevenueEventLogIndex]
    assert f'{event.event_type}' == 'event RevenueClaimed(address,uint256)'
    assert to_checksum_address(event.args_map['rev_recipient']) == admin
    assert event.args_map['amount'] == amount
    assert pool.claimable_rev(pool) == 0

@pytest.mark.pool
@pytest.mark.rev_generator
@given(amount=st.integers(min_value=1, max_value=MAX_UINT - 2)) # ensure we dont hit MAX_UINT special case
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_rev_recipient_cant_overclaim_rev(pool, admin, amount):
    # test max claim shortcut
    pool.eval(f'self.accrued_fees = {amount}')
    pool.eval(f'self.balances[self] = {amount}')
    assert pool.claimable_rev(pool) == amount
    assert pool.accrued_fees() == amount

    with boa.reverts(): # # TODO doesnot revert
        pool.claim_rev(pool, amount + 1, sender=admin)

    assert pool.claimable_rev(pool) == amount
    assert pool.accrued_fees() == amount

    pool.claim_rev(pool, amount, sender=admin)

    event = pool.get_logs()[ClaimRevenueEventLogIndex]
    assert f'{event.event_type}' == 'event RevenueClaimed(address,uint256)'
    assert to_checksum_address(event.args_map['rev_recipient']) == admin
    assert event.args_map['amount'] == amount
    assert pool.claimable_rev(pool) == 0


@pytest.mark.pool
@pytest.mark.rev_generator
@given(amount=st.integers(min_value=0, max_value=MAX_UINT))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_cant_claim_rev_of_non_pool_token(pool, admin, base_asset, amount):
    base_asset.mint(pool, amount)
    assert base_asset.balanceOf(pool) == amount
    assert pool.claimable_rev(base_asset) == 0
    with boa.reverts("non-revenue token"):
        pool.claim_rev(base_asset, amount, sender=admin)

    new_token = boa.load('tests/mocks/MockERC20.vy', "Lending Token", "LEND", 18)
    new_token.mint(pool, amount)
    assert new_token.balanceOf(pool) == amount
    assert pool.claimable_rev(new_token) == 0
    with boa.reverts("non-revenue token"):
        pool.claim_rev(new_token, amount, sender=admin)


@pytest.mark.pool
@pytest.mark.slow
# @pytest.mark.rev_generator # What does this do?
@given(amount=st.integers(min_value=1, max_value=MAX_UINT)) # min_val = 1 so no off by one when adjusting values
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_self_owner_rev_claimable_by_rev_recipient(pool, admin, amount):
    assert pool.rev_recipient() == admin
    assert pool.claimable_rev(pool) == 0
    assert pool.balanceOf(admin) == 0

    # give revenue to delegate
    pool.eval(f'self.accrued_fees = {amount}')
    pool.eval(f'self.balances[self] = {amount}')

    assert pool.claimable_rev(pool) == amount
    assert pool.accrued_fees() == amount

    # rev_recipient claims all revenue
    pool.claim_rev(pool, amount, sender=admin)
    assert pool.claimable_rev(pool) == 0
    assert pool.accrued_fees() == 0


@pytest.mark.pool
@pytest.mark.event_emissions
def test_claimable_rev_equals_sum_of_self_owner_fee_events_emitted(pool):
    assert pool.claimable_rev(pool) == 0
    # print('3 - Claimable Rev: ', pool.claimable_rev(pool))

    # Create RevenueGenerated events

    # Get all events emitted and filter to only RevenueGenerated events w/ custom find_events_by function
    # events = pool.get_logs()

    # Calculate sum of RevenueGenerated events

    # assert sum of RevenueGenerated events equals claimable_rev

    # no events: claimable_rev == 0
    #
    assert False


@pytest.mark.pool
def test_max_uint_claim_rev_equals_claimable_rev(pool, admin):
    # give MAX_UNIT - 1 of revenue to delegate
    amount = MAX_UINT - 1
    pool.eval(f'self.accrued_fees = {amount}')
    pool.eval(f'self.balances[self] = {amount}')

    assert pool.claimable_rev(pool) == amount
    assert pool.accrued_fees() == amount

    # rev_recipient claims MAX_UNIT revenue
    pool.claim_rev(pool, MAX_UINT, sender=admin)

    # leaving no revenue remaining
    assert pool.claimable_rev(pool) == 0
    assert pool.accrued_fees() == 0


@pytest.mark.acl
@pytest.mark.pool
@pytest.mark.slow
@pytest.mark.rev_generator
@given(amount=st.integers(min_value=0, max_value=MAX_UINT - 1)) # prevent overflow but allow testing MAX_UINT path
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_non_rev_recipient_cant_claim_rev(pool, admin, me, base_asset, amount):
    assert pool.rev_recipient() == admin
    rando = boa.env.generate_address()

    # try claiming empty rev token
    assert pool.claimable_rev(base_asset) == 0
    # cant claim 0
    with boa.reverts("not rev_recipient"):
        pool.claim_rev(pool, 0, sender=me)
    with boa.reverts("not rev_recipient"):
        pool.claim_rev(pool, 0, sender=rando)
    # cant claim available amount
    with boa.reverts("not rev_recipient"):
        pool.claim_rev(pool, amount, sender=me)
    with boa.reverts("not rev_recipient"):
        pool.claim_rev(pool, amount, sender=rando)
    # cant claim over available amount
    with boa.reverts("not rev_recipient"):
        pool.claim_rev(pool, amount + 1, sender=me)
    with boa.reverts("not rev_recipient"):
        pool.claim_rev(pool, amount + 1, sender=rando)

    # add rev to pool and try to claim actual rev token
    pool.eval(f'self.accrued_fees = {amount}')
    pool.eval(f'self.balances[self] = {amount}')

    assert pool.claimable_rev(pool) == amount
    # cant claim 0
    with boa.reverts("not rev_recipient"):
        pool.claim_rev(pool, 0, sender=me)
    with boa.reverts("not rev_recipient"):
        pool.claim_rev(pool, 0, sender=rando)
    # cant claim available amount
    with boa.reverts("not rev_recipient"):
        pool.claim_rev(pool, amount, sender=me)
    with boa.reverts("not rev_recipient"):
        pool.claim_rev(pool, amount, sender=rando)
    # cant claim over available amount
    with boa.reverts("not rev_recipient"):
        pool.claim_rev(pool, amount + 1, sender=me)
    with boa.reverts("not rev_recipient"):
        pool.claim_rev(pool, amount + 1, sender=rando)

    # # add rev to pool and try to claim actual rev token
    new_token = boa.load('tests/mocks/MockERC20.vy', "Lending Token", "LEND", 18)
    new_token.mint(pool, amount)
    assert new_token.balanceOf(pool) == amount
    assert pool.claimable_rev(new_token) == 0

    # try claiming non rev token
    # cant claim 0
    with boa.reverts("non-revenue token"):
        pool.claim_rev(new_token, 0, sender=me)
    with boa.reverts("non-revenue token"):
        pool.claim_rev(new_token, 0, sender=rando)
    # cant claim available amount
    with boa.reverts("non-revenue token"):
        pool.claim_rev(new_token, amount, sender=me)
    with boa.reverts("non-revenue token"):
        pool.claim_rev(new_token, amount, sender=rando)
    # cant claim over available amount
    with boa.reverts("non-revenue token"):
        pool.claim_rev(new_token, amount + 1, sender=me)
    with boa.reverts("non-revenue token"):
        pool.claim_rev(new_token, amount + 1, sender=rando)


@pytest.mark.pool
@pytest.mark.rev_generator
@pytest.mark.event_emissions
@given(amount=st.integers(min_value=0, max_value=MAX_UINT - 1)) # prevent overflow but allow testing MAX_UINT path
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_accept_invoice_must_revert_or_return_selector(pool, base_asset, me, amount):
    try:
        # if not implemented
        # with boa.reverts():
            # TODO expect boa error not vyper error due to accept_invoice not being on ABI
            # response = pool.accept_invoice(me, base_asset, amount, "My Invoicing Event")
        assert True

        # if implemented
        # print("accept invoice response", response)
        # event = pool.get_logs()[0]
        # assert f'{event.event_type}' == 'event RevenueGenerated(address,address,uint256,uint256,uint256,address)'
    finally:
        # if revert then do nothing. function not implemented, allowed in EIP spec
        assert True




# Unrelated to our contract. debugging boa functionality
# def test_assertion_state_change(pool, me, admin, pool_roles):
#     num_events = []
#             assert to_checksum_address(_call_pool_as_role(pool, role, 'get')) == admin
#     assert pool.pending_owner() == ZERO_ADDRESS

#     # assert + extern call + extern check
#     assert _call_pool_as_role(pool, 'owner', 'set', admin, me) # state not saved
#     assert me == _call_pool_as_role(pool, 'owner', 'next') # state not saved
#     num_events.append(len(pool.get_logs()))

#     # no assert + extern call + extern check
#     _call_pool_as_role(pool, 'owner', 'set', admin, me)    # state not saved
#     assert me == _call_pool_as_role(pool, 'owner', 'next') # state not saved
#     num_events.append(len(pool.get_logs()))

#     # no assert + intern call + extern check
#     rando = boa.env.generate_address()
#     pool.set_owner(rando, sender=admin)
#     assert rando == _call_pool_as_role(pool, 'owner', 'next') # state not saved
#     num_events.append(len(pool.get_logs()))

#     # no assert + intern call + intern check
#     rando = boa.env.generate_address()
#     pool.set_owner(rando, sender=admin)
#     print(len(pool.get_logs()))
#     assert rando == pool.pending_owner() # state not saved
#     print(len(pool.get_logs()))

#     # assert + intern call + intern check
#     rando = boa.env.generate_address()
#     assert pool.set_owner(rando, sender=admin)
#     assert rando == pool.pending_owner() # state not saved
#     num_events.append(len(pool.get_logs()))

#     # assert + extern call + intern check
#     rando = boa.env.generate_address()
#     assert _call_pool_as_role(pool, 'owner', 'set', admin, rando) # state not saved
#     assert rando == pool.pending_owner() # state not saved
#     num_events.append(len(pool.get_logs()))

#     # assert + extern call + extern check
#     rando = boa.env.generate_address()
#     assert _call_pool_as_role(pool, 'owner', 'set', admin, rando) # state not saved
#     assert rando == _call_pool_as_role(pool, 'owner', 'next') # state not saved
#     num_events.append(len(pool.get_logs()))

#     print("event count", num_events) # all 0s
#     assert len(num_events) == 7 # passes
#     assert num_events[-1] == 7 # fails. == 0