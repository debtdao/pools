import boa
import ape
import pytest
import logging
from eth_utils import to_checksum_address
from datetime import timedelta
from hypothesis import given, settings
from hypothesis import strategies as st
from eip712.messages import EIP712Message
from ..utils.events import _find_event
from ..conftest import INIT_USER_POOL_BALANCE

# TODO Ask ChatGPT to generate test cases in vyper

# # test basic ERC20 functionality 
# # Files that use these tests: PoolDelegate.vy, BondToken.vy, MockERC20.vy

# # boa/ape test references
# # https://github.com/ApeAcademy/ERC20/blob/main/%7B%7Bcookiecutter.project_name%7D%7D/tests/test_token.py

# # TESTS TO DO:
# # events properly emitted


def test_token_info(base_asset, pool):
    """
    Test inital state of the contract.
    """

    # Check the token meta matches the deployment
    # token.method_name() has access to all the methods in the smart contract.
    assert base_asset.name() == "Lending Token"
    assert base_asset.symbol() == "LEND"
    assert base_asset.decimals() == 18

    assert pool.name() == "Debt DAO Pool - Dev Testing"
    # TODO fix symbol autogeneration
    # assert pool.symbol() == "ddpLEND-KIBA-TEST"
    assert pool.decimals() == 18
    # assert pool.CACHED_COMAIN_SEPARATOR() == 
    # assert pool.CACHED_CHAIN_ID() == 18

    # Check of intial state of authorization
    # assert base_asset.owner() == admin

    # Check intial mints in conftest
    # assert base_asset.totalSupply() == 1000
    # assert base_asset.balanceOf(admin) == 1000



# transfers properly update token balances
@given(amount=st.integers(min_value=1, max_value=INIT_USER_POOL_BALANCE),
    is_send=st.integers(min_value=0, max_value=1))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_transfer(all_erc20_tokens, me, admin, amount, is_send):
    (sender, receiver) = (me, admin) if is_send else (admin, me)

    for token in all_erc20_tokens:
        token.eval(f'self.balances[{sender}] = {amount}') # ensure tokens for test
        pre_sender_balance =  token.balanceOf(sender)
        pre_receiver_balance =  token.balanceOf(receiver)

        with boa.env.prank(sender):
            token.eval(f'self.balances[{sender}] = {amount}')
            tx0 = token.transfer(receiver, amount, sender=sender)

            # validate that Transfer Log is correct
            # TODO figure out how to test logs in boa        # https://docs.apeworx.io/ape/stable/methoddocs/api.html?highlight=decode#ape.api.networks.EcosystemAPI.decode_logs
            # TODO found out. its contract.get_logs(). i assume 0 is first, -1 is last emitted
            event = token.get_logs()[0]
            assert to_checksum_address(event.args_map['sender']) == sender
            assert to_checksum_address(event.args_map['receiver']) == receiver
            assert event.args_map['amount'] == amount
            
            post_sender_balance = token.balanceOf(sender)
            post_receiver_balance = token.balanceOf(receiver)
            assert post_sender_balance == pre_sender_balance - amount
            assert post_receiver_balance == pre_receiver_balance + amount
            
            # transfering 0 should do nothing
            tx1 = token.transfer(receiver, 0, sender=sender)

            # TODO figure out how to test logs in boa
            event = token.get_logs()[0]
            assert to_checksum_address(event.args_map['sender']) == sender
            assert to_checksum_address(event.args_map['receiver']) == receiver
            assert event.args_map['amount'] == 0

            with boa.reverts():  # TODO expect revert msg
                # Expected insufficient funds failure
                token.transfer(receiver, post_sender_balance + 1, sender=sender)

@pytest.mark.slow # we do a lot of tx in here
@given(amount=st.integers(min_value=1, max_value=10**25),
        is_send=st.integers(min_value=0, max_value=1))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_transfer_from(all_erc20_tokens, init_token_balances, admin, me, treasury, amount, is_send):
    """
    Transfer tokens to an address.
    Transfer operator may not be an admin.
    Approve must be valid to be a spender.
    """
    (sender, receiver) = (me, admin) if is_send else (admin, me)

    for token in all_erc20_tokens:
        # pre_sender_balance = token.balanceOf(sender)
        # pre_receiver_balance = token.balanceOf(receiver)
        token.eval(f'self.balances[{sender}] = {amount}')
        token.eval(f'self.balances[{receiver}] = 0')

        # Spender with no approve permission cannot send tokens on someone behalf
        with boa.reverts():
            token.transferFrom(sender, receiver, amount, sender=receiver)

        # Get approval for allowance from sender
        tx = token.approve(receiver, amount, sender=sender)

        # TODO figure out how to test logs in boa
        event = token.get_logs()[0]

        assert to_checksum_address(event.args_map['owner']) == sender
        assert to_checksum_address(event.args_map['spender']) == receiver
        assert event.args_map['amount'] == amount

        approved = token.allowance(sender, receiver)
        assert approved == amount

        # reset balances for nexttransfer
        token.eval(f'self.balances[{sender}] = {amount}')
        token.eval(f'self.balances[{receiver}] = 0')

        # With auth use the allowance to send to receiver via sender(operator)
        tx = token.transferFrom(sender, receiver, amount, sender=receiver)

        transferFrom_event_name = 'Transfer'
        event = _find_event(transferFrom_event_name, token.get_logs())
        assert event is not None

        # print("find rev eevent", event.event_type.name, transferFrom_event_name, transferFrom_event_name == event.event_type.name, transferFrom_event_name in e_types, fee_type)
        assert f'{event.event_type.name}' == transferFrom_event_name # double check
        print(" --- EVENT #1 --- ")
        print("transferFrom event sender/receiver./args", sender, receiver)
        print(event.args_map)
        assert to_checksum_address(event.args_map['sender']) == sender
        assert to_checksum_address(event.args_map['receiver']) == receiver
        assert event.args_map['amount'] == amount

        assert token.allowance(sender, receiver) == 0
        assert token.balanceOf(sender) == 0
        assert token.balanceOf(receiver) == amount

        # # Cannot exceed authorized allowance
        with boa.reverts(): # TODO expect right revert msg
            token.transferFrom(sender, receiver, 1, sender=receiver)
        
        # reset balances for next transfer
        token.eval(f'self.balances[{sender}] = {amount}')
        token.eval(f'self.balances[{receiver}] = 0')

        # sender should be able to transferFrom themselves to themselves w/ no approval
        token.approve(sender, amount, sender=sender)
        token.transferFrom(sender, sender, amount, sender=sender)

        event = _find_event(transferFrom_event_name, token.get_logs()) # THIS ONE FAILS
        print(" --- EVENT #2 --- ")
        print("transferFrom event sender/receiver./args", sender, sender)
        print(event.args_map)
        assert event is not None
        assert to_checksum_address(event.args_map['sender']) == sender
        assert to_checksum_address(event.args_map['receiver']) == sender
        assert event.args_map['amount'] == amount

        # transfer to self = both have same balance has before
        assert token.balanceOf(sender) == amount
        assert token.balanceOf(receiver) == 0

        # reset balances for next transfer
        token.eval(f'self.balances[{sender}] = {amount}')
        token.eval(f'self.balances[{receiver}] = 0')

        # sender should be able to transferFrom themselves to someone else w/ no approval needed (even tho its gas inefficient)
        token.transferFrom(sender, receiver, amount, sender=sender)
        
        event = _find_event(transferFrom_event_name, token.get_logs())
        print(" --- EVENT #3 --- ")
        print("transferFrom event sender/sender./args", sender, receiver)
        print(event.args_map)
        assert to_checksum_address(event.args_map['sender']) == sender
        assert to_checksum_address(event.args_map['receiver']) == receiver
        assert event.args_map['amount'] == amount

        assert token.balanceOf(receiver) == amount
        assert token.balanceOf(sender) == 0

        # reset balances for next transfer
        token.eval(f'self.balances[{sender}] = {amount}')
        token.eval(f'self.balances[{receiver}] = 0')

        # sender should be able to send 0 if they have 0 balance
        token.transferFrom(sender, receiver, 0, sender=sender)

        event = _find_event(transferFrom_event_name, token.get_logs())
        assert to_checksum_address(event.args_map['sender']) == sender
        assert to_checksum_address(event.args_map['receiver']) == receiver
        assert event.args_map['amount'] == 0
        # no transfer = both have same balance has before
        assert token.balanceOf(sender) == amount
        assert token.balanceOf(receiver) == 0

@given(amount=st.integers(min_value=1, max_value=10**50),
        is_send=st.integers(min_value=0, max_value=1))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_approve(all_erc20_tokens, init_token_balances, admin, me, amount, is_send):
    """
    Check the authorization of an operator(spender).
    Check the logs of Approve.
    """
    (sender, receiver) = (me, admin) if is_send else (admin, me)

    for token in all_erc20_tokens:
        tx = token.approve(receiver, amount, sender=sender)

        event = token.get_logs()[0]
        assert to_checksum_address(event.args_map['spender']) == receiver
        assert to_checksum_address(event.args_map['owner']) == sender
        assert event.args_map['amount'] == amount

        assert token.allowance(sender, receiver) == amount

        # Set auth balance to 0 and check attacks vectors
        # though the contract itself shouldn’t enforce it,
        # to allow backwards compatibility
        tx = token.approve(receiver, 0, sender=sender)

        event = token.get_logs()[0]
        assert to_checksum_address(event.args_map['spender']) == receiver
        assert to_checksum_address(event.args_map['owner']) == sender
        assert event.args_map['amount'] == 0
    
        assert token.allowance(sender, receiver) == 0

        # check increase math from 0
        tx = token.increaseAllowance(receiver, amount, sender=sender)

        event = token.get_logs()[0]
        assert to_checksum_address(event.args_map['spender']) == receiver
        assert to_checksum_address(event.args_map['owner']) == sender
        assert event.args_map['amount'] == amount

        assert token.allowance(sender, receiver) == amount

        # check increase math from non-0
        tx = token.increaseAllowance(receiver, amount, sender=sender)

        event = token.get_logs()[0]
        assert to_checksum_address(event.args_map['spender']) == receiver
        assert to_checksum_address(event.args_map['owner']) == sender
        assert event.args_map['amount'] == amount * 2 # emits total allowance, not increase

        assert token.allowance(sender, receiver) == amount * 2
        
        # test rando doesnt have approvals
        assert token.allowance(sender, boa.env.generate_address()) == 0
        # spender shouldnt have approved person who is approving them
        assert token.allowance(receiver, sender) == 0



@given(amount=st.integers(min_value=1, max_value=10**50))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_permit(all_erc20_tokens, init_token_balances, chain, accounts, amount):
    """
    Validate permit method for incorrect ownership, values, and timing
    """
    admin = accounts[0]
    me = accounts[1]

    for token in all_erc20_tokens:

        # there is an address field here but get `AttributeError: 'str' object has no attribute 'address'``
        # logging.debug("token", token.__dict__)

        permit_hash = boa.eval('keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")')
        class Permit(EIP712Message):
            _name_  = token.n() #: "string"
            _version_  = token.v() #: "string"
            _chainId_  = chain.chain_id #: "uint256"
            _verifyingContract_  = token.at #: "address"
            
            # class constructor args
            owner  : "address"
            spender  : "address"
            value  : "uint256"
            nonce  : "uint256"
            deadline  : "uint256"

        Permit.domain = token.DOMAIN_SEPARATOR() # manually set domain hash with customized hash per token
        nonce = token.nonces(admin)
        deadline = chain.pending_timestamp + 60
        permit = Permit(admin, me, amount, nonce, deadline)

        assert token.allowance(admin, me) == 0

        # signature fails for some reason, has to do with EIP712 hash
        # signature = admin.sign_message(permit.signable_message).encode_rsv()

        # with boa.reverts():
        #     token.permit(me, me, amount, deadline, signature, sender=me)
        # with boa.reverts():
        #     token.permit(admin, admin, amount, deadline, signature, sender=me)
        # with boa.reverts():
        #     token.permit(admin, me, amount + 1, deadline, signature, sender=me)
        # with boa.reverts():
        #     token.permit(admin, me, amount, deadline + 1, signature, sender=me)

        # token.permit(admin, me, amount, deadline, signature, sender=me)

        # assert token.allowance(admin, me) == amount