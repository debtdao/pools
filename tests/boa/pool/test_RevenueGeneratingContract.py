# TODO check tests against most recent 

import boa
import ape
import pytest
import logging
from boa.vyper.contract import BoaError
from hypothesis import given, settings
from hypothesis import strategies as st
from hypothesis.stateful import RuleBasedStateMachine, run_state_machine_as_test, rule, invariant
from datetime import timedelta

MAX_UINT = 115792089237316195423570985008687907853269984665640564039457584007913129639935
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"


# Table of Contents

# Role ACL and state changes
# 1. only {role} can set_{role}
# 3. {role} cant call accept_{role}
# 5. no one can accept_{role} if pending_{role} is null
# 6. no one can set_{role} if {role} is null
# 2. pending_{role} can call accept_{role}
# 2. emits NewPending{role} event with appropriate new_{role}
# 4. emits Accepted{role} event with appropriate {role}

# Control of revenue stream
# 1. rev_recipient can claim_rev
# 1. non rev_recipient cant claim_rev
# 1. self.owner cant claim_rev
# 2. (invariant) all self.owner rev is claimable by self.rev_recipient
# 3. (invariant) claimable rev == sum of self.owner fees events emitted
# 4. MUST emit RevenueGenerated event even if event.revenue == 0
# 5. (invariant) max_uint claim_rev is claimable_rev
# 6. cant claim more than claimable_rev from claim_rev
# 9. claim rev should fail if push pa yments implemented
# 11. claim_rev should not fail if payments claimable by rev_recipient
# 7. can claim_rev up to claimable_rev 
# 7. if accept_ivoice doesnt revert, it must return IRevenueGenerator.payInvoice.selector 
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

def _call_pool_as_role(pool, role, action, caller = boa.env.generate_address(), *args):
    # generalized testing for role based functions
    func_name = _get_role_actions(role)[action]
    # get actual function on contract based on name of func for role
    func = getattr(pool, func_name, lambda x: "No func for role found")
    print("func to call", func, args)
    # call pool with args if provided
    # TODO: state is not properly updated/persisted with these calls.
    # i think getattr is calling contract class directly and not simulating with boa so these calls do nothing
    return func(*args, sender=caller) if len(args) > 0 else func(sender=caller) 


@pytest.mark.pool
@pytest.mark.rev_generator
def test_only_current_role_holder_can_set_role(pool, me, admin, roles):
    # TODO generalize role tests with _call_pool_as_role
    for role in roles:

        role_owner = _call_pool_as_role(pool, role, 'get')
        assert role_owner == admin
        # manual check incase _call_pool_as_role doesnt work
        assert pool.owner() == admin

        with boa.reverts(f"not {role}"): # TODO expect revert msg
            # known party cant set themselves as delegate
            _call_pool_as_role(pool, role, 'set', me, me) # state not saved
            # assert pool.set_owner(me, sender=me)  # state not saved
            # pool.set_owner(me, sender=me)  # STATE SAVED


        with boa.reverts(f"not {role}"): # TODO expect revert msg
            # anon cant set anon as delegate
            _call_pool_as_role(pool, role, 'set', boa.env.generate_address(), boa.env.generate_address())
            # pool.set_owner(boa.env.generate_address(), sender=boa.env.generate_address())

        _call_pool_as_role(pool, role, 'set', admin, me)
        # pool.set_owner(me, sender=admin)
        # assert pool.set_owner(me, sender=admin) == True

        # # print(f"next {role}", _call_pool_as_role(pool, role, 'next'))
        assert me == _call_pool_as_role(pool, role, 'next')
        # assert pool.pending_owner() == me
        _call_pool_as_role(pool, role, 'accept', me)
        # pool.accept_owner(sender=me)
        
        assert pool.owner() == me
        assert pool.pending_owner() == me
        # print("new pending owner", pool.pending_owner(), _call_pool_as_role(pool, role, 'next'))

        with boa.reverts(f"not {role}"): # TODO expect revert msg
            # ensure old owner can no longer has access
            _call_pool_as_role(pool, role, 'set', admin, admin)
            # pool.set_owner(admin, sender=admin)

        # pool.set_owner(admin, sender=me)
        _call_pool_as_role(pool, role, 'set', me, admin)
        assert _call_pool_as_role(pool, role, 'get', admin)== me
        assert _call_pool_as_role(pool, role, 'next', admin)== admin
        _call_pool_as_role(pool, role, 'accept', admin)
        assert _call_pool_as_role(pool, role, 'get', admin)== admin
        assert _call_pool_as_role(pool, role, 'next', admin)== admin

@pytest.mark.pool
@pytest.mark.rev_generator
def test_can_override_pending_role_before_accepted(pool, me, admin):
    assert pool.owner() == admin

    pool.set_owner(me, sender=admin)
    assert pool.pending_owner() == me

    rando = boa.env.generate_address()
    pool.set_owner(rando, sender=admin)
    assert pool.pending_owner() == rando

    with boa.reverts("not pending owner"):
        pool.accept_owner(sender=me)

@pytest.mark.pool
@pytest.mark.rev_generator        
def test_cant_accept_role_as_current_role_holder(pool, me, admin):
    assert pool.owner() == admin

    pool.set_owner(me, sender=admin)
    assert pool.pending_owner() == me

    with boa.reverts(): # TODO expect revert msg
        pool.accept_owner(sender=admin)
        pool.accept_owner(sender=boa.env.generate_address())

    pool.accept_owner(sender=me)

@pytest.mark.pool
@pytest.mark.rev_generator
def test_can_accept_role_as_pending_holder(pool, me, admin):
    assert pool.owner() == admin

    pool.set_owner(me, sender=admin)
    assert pool.pending_owner() == me

    pool.accept_owner(sender=me)

@pytest.mark.pool
@pytest.mark.rev_generator
def test_can_accept_role_as_pending_holder(pool, me, admin):
    assert pool.owner() == admin

    pool.set_owner(me, sender=admin)
    assert pool.pending_owner() == me

    pool.accept_owner(sender=me)

@pytest.mark.pool
@pytest.mark.rev_generator
@pytest.mark.event_emissions
def test_setting_role_emits_pending_role_event(pool, me, admin):
    assert pool.owner() == admin
    pool.set_owner(me, sender=admin)
    event = pool.get_logs()[0]
    print(event, event.args_map, event.event_type)
    assert event.args_map['new_recipient'] == me
    assert f'{event.event_type}' == 'event NewPendingOwner(address)'


@pytest.mark.pool
@pytest.mark.rev_generator
@pytest.mark.event_emissions
def test_accepting_role_emits_new_role_event(pool, me, admin):
    assert pool.owner() == admin

    pool.set_owner(me, sender=admin)
    pool.accept_owner(sender=me)
    event = pool.get_logs()[0]
    print(event, event.args_map, event.event_type)
    assert event.args_map['new_recipient'] == me
    assert f'{event.event_type}' == 'event UpdateOwner(address)'
    # assert False

@pytest.mark.pool
@pytest.mark.rev_generator
def test_cant_accept_null_role(pool, me, admin):
    assert pool.owner() == admin
    assert pool.pending_owner() == ZERO_ADDRESS

    with boa.reverts():
        pool.accept_owner(sender=admin)

    with boa.reverts():
        pool.accept_owner(sender=me)

    with boa.reverts():
        pool.accept_owner(sender=boa.env.generate_address())

    logs = pool.get_logs()
    assert len(logs) == 0



# Unrelated to our contract. debugging boa functionality
@pytest.mark.rev_generator
def test_assertion_state_change(pool, me, admin, roles):
    num_events = []

    assert pool.owner() == admin
    assert pool.pending_owner() == ZERO_ADDRESS

    # assert + extern call + extern check
    assert _call_pool_as_role(pool, 'owner', 'set', admin, me) # state not saved
    assert me == _call_pool_as_role(pool, 'owner', 'next') # state not saved
    num_events.append(len(pool.get_logs()))
    
    # no assert + extern call + extern check
    _call_pool_as_role(pool, 'owner', 'set', admin, me)    # state not saved
    assert me == _call_pool_as_role(pool, 'owner', 'next') # state not saved
    num_events.append(len(pool.get_logs()))

    # no assert + intern call + extern check
    rando = boa.env.generate_address()
    pool.set_owner(rando, sender=admin)
    assert rando == _call_pool_as_role(pool, 'owner', 'next') # state not saved
    num_events.append(len(pool.get_logs()))

    # no assert + intern call + intern check
    rando = boa.env.generate_address()
    pool.set_owner(rando, sender=admin)
    print(len(pool.get_logs()))
    assert rando == pool.pending_owner() # state not saved
    print(len(pool.get_logs()))

    # assert + intern call + intern check
    rando = boa.env.generate_address()
    assert pool.set_owner(rando, sender=admin)
    assert rando == pool.pending_owner() # state not saved
    num_events.append(len(pool.get_logs()))

    # assert + extern call + intern check
    rando = boa.env.generate_address()
    assert _call_pool_as_role(pool, 'owner', 'set', admin, rando) # state not saved
    assert rando == pool.pending_owner() # state not saved
    num_events.append(len(pool.get_logs()))

    # assert + extern call + extern check
    rando = boa.env.generate_address()
    assert _call_pool_as_role(pool, 'owner', 'set', admin, rando) # state not saved
    assert rando == _call_pool_as_role(pool, 'owner', 'next') # state not saved
    num_events.append(len(pool.get_logs()))

    print("event count", num_events) # all 0s
    assert len(num_events) == 7 # passes
    assert num_events[-1] == 7 # fails. == 0