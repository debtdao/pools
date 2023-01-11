import boa
import ape
import pytest
import logging
from hypothesis import given, settings
from hypothesis import strategies as st
from datetime import timedelta
from math import exp

# # test basic ERC20 functionality 
# # Files that use these tests: PoolDelegate.vy, BondToken.vy

# # boa/ape test references
# # https://github.com/ApeAcademy/ERC20/blob/main/%7B%7Bcookiecutter.project_name%7D%7D/tests/test_token.py

# # TESTS TO DO:
# # events properly emitted
# # invairants around total supply with mint/burn


# # Standard test comes from the interpretation of EIP-20
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
MAX_UINT = 115792089237316195423570985008687907853269984665640564039457584007913129639935


# https://docs.apeworx.io/ape/stable/methoddocs/managers.html?highlight=project#module-ape.managers.project.manager

def test_initial_state(lending_token, pool_token, bond_token):
    """
    Test inital state of the contract.
    """

    # Check the token meta matches the deployment
    # token.method_name() has access to all the methods in the smart contract.
    assert lending_token.name() == "Lending Token"
    assert lending_token.symbol() == "LEND"
    assert lending_token.decimals() == 18

    assert pool_token.name() == "Debt DAO Pool - Dev Testing"
    # TODO fix symbol autogeneration
    # assert pool_token.symbol() == "ddpLEND-KIBA-TEST"
    assert pool_token.decimals() == 18

    assert bond_token.name() == "Bondage Token"
    assert bond_token.symbol() == "BONDAGE"
    assert bond_token.decimals() == 18

    # Check of intial state of authorization
    # assert lending_token.owner() == admin

    # Check intial mints in conftest
    # assert lending_token.totalSupply() == 1000
    # assert lending_token.balanceOf(admin) == 1000



# transfers properly update token balances
@given(amount=st.integers(min_value=1, max_value=10**25),
    is_send=st.integers(min_value=0, max_value=1))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_transfer(all_erc20_tokens, init_token_balances, me, admin, amount, is_send):
    (sender, receiver) = (me, admin) if is_send else (admin, me)

    for token in all_erc20_tokens:
        pre_sender_balance =  token.balanceOf(sender)
        pre_receiver_balance =  token.balanceOf(receiver)

        with boa.env.prank(sender):
            tx0 = token.transfer(receiver, amount, sender=sender)

            # validate that Transfer Log is correct
            # TODO figure out how to test logs in boa        # https://docs.apeworx.io/ape/stable/methoddocs/api.html?highlight=decode#ape.api.networks.EcosystemAPI.decode_logs
            # logs0 = list(tx0.decode_logs(token.Transfer))
            # assert len(logs0) == 1
            # assert logs0[0].sender == sender
            # assert logs0[0].receiver == receiver
            # assert logs0[0].amount == amount
            
            post_sender_balance = token.balanceOf(sender)
            post_receiver_balance = token.balanceOf(receiver)
            assert post_sender_balance == pre_sender_balance - amount
            assert post_receiver_balance == pre_receiver_balance + amount
            
            # transfering 0 should do nothing
            tx1 = token.transfer(receiver, 0, sender=sender)

            # TODO figure out how to test logs in boa
            # logs1 = list(tx0.decode_logs(token.Transfer))
            # assert len(logs1) == 1
            # assert logs1[0].sender == sender
            # assert logs1[0].receiver == receiver
            # assert logs1[0].amount == 0

            with boa.reverts():  # TODO expect right revert msg
                # Expected insufficient funds failure
                token.transfer(receiver, post_sender_balance + 1, sender=sender)


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

        pre_sender_balance = token.balanceOf(sender)
        pre_receiver_balance = token.balanceOf(receiver)

        # Spender with no approve permission cannot send tokens on someone behalf
        with boa.reverts():
            token.transferFrom(sender, receiver, amount, sender=receiver)

        # Get approval for allowance from sender
        tx = token.approve(receiver, amount, sender=sender)

        # TODO figure out how to test logs in boa
        # logs = list(tx.decode_logs(token.Approval))
        # assert len(logs) == 1
        # assert logs[0].sender == sender
        # assert logs[0].receiver == receiver
        # assert logs[0].amount == amount

        approved = token.allowance(sender, receiver)
        assert approved == amount 

        # logging.debug("approved transferFrom amount", approved, amount)
        print("approved transferFrom amount", approved, amount)

        # With auth use the allowance to send to receiver via sender(operator)
        tx = token.transferFrom(sender, receiver, amount, sender=receiver)

        # # TODO figure out how to test logs in boa
        # # logs = list(tx.decode_logs(token.Transfer))
        # # assert len(logs) == 1
        # # assert logs[0].sender == admin
        # # assert logs[0].receiver == receiver
        # # assert logs[0].amount == 200

        assert token.allowance(sender, receiver) == 0
        assert token.balanceOf(sender) == pre_sender_balance - amount
        assert token.balanceOf(receiver) == pre_receiver_balance + amount

        # # Cannot exceed authorized allowance
        with boa.reverts(): # TODO expect right revert msg
            token.transferFrom(sender, receiver, 1, sender=receiver)
        
        # receiver should be able to transferFrom themselves to themselves
        token.transferFrom(receiver, receiver, amount, sender=receiver)
        # both have same balance has before
        assert token.balanceOf(sender) == pre_sender_balance - amount
        assert token.balanceOf(receiver) == pre_receiver_balance + amount
        # todo test logs

        # receiver should be able to transferFrom themselves even tho its gas inefficient
        token.transferFrom(receiver, sender, pre_receiver_balance + amount, sender=receiver)

        assert token.balanceOf(sender) == pre_sender_balance + pre_receiver_balance
        assert token.balanceOf(receiver) == 0

        # sender should be able to send 0 if they have 0 balance
        token.transferFrom(receiver, sender, 0, sender=receiver)
        # both have same balance has before
        assert token.balanceOf(sender) == pre_sender_balance + pre_receiver_balance
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

        tx = token.approve(sender, amount, sender=receiver)

        # logs = list(tx.decode_logs(token.Approval))
        # assert len(logs) == 1
        # assert logs[0].receiver == receiver
        # assert logs[0].sender == sender
        # assert logs[0].amount == amount

        assert token.allowance(receiver, sender) == amount

        # Set auth balance to 0 and check attacks vectors
        # though the contract itself shouldn’t enforce it,
        # to allow backwards compatibility
        tx = token.approve(sender, 0, sender=receiver)

        # logs = list(tx.decode_logs(token.Approval))
        # assert len(logs) == 1
        # assert logs[0].receiver == receiver
        # assert logs[0].sender == sender
        # assert logs[0].amount == 0

        assert token.allowance(admin, sender) == 0

@given(amount=st.integers(min_value=1, max_value=10**50),
        is_send=st.integers(min_value=0, max_value=1))
@settings(max_examples=100, deadline=timedelta(seconds=1000))
def test_mint(all_erc20_tokens, init_token_balances, token, admin, me, amount, is_send):
    """
    Create an approved amount of tokens.
    """
    (sender, receiver) = (me, admin) if is_send else (admin, me)
    for token in all_erc20_tokens:
        totalSupply = token.totalSupply()

        sender_balance = token.balanceOf(sender)
        assert sender_balance == init_token_balances

        tx = token.mint(sender, amount, sender=receiver)

        # logs = list(tx.decode_logs(token.Transfer))
        # assert len(logs) == 1
        # assert logs[0].sender == ZERO_ADDRESS
        # assert logs[0].sender == sender.address
        # assert logs[0].amount == amount

        assert token.balanceOf(sender) == sender_balance + amount

        assert token.totalSupply() == totalSupply + amount


# def test_add_minter(token, admin, accounts):
#     """
#     Test adding new minter.
#     Must trigger MinterAdded Event.
#     Must return true when checking if target isMinter
#     """
#     target = accounts[1]
#     assert token.isMinter(target) is False
#     token.addMinter(target, sender=admin)
#     assert token.isMinter(target) is True


# def test_add_minter_targeting_zero_address(token, admin):
#     """
#     Test adding new minter targeting ZERO_ADDRESS
#     Must trigger a ContractLogicError (ape.exceptions.ContractLogicError)
#     """
#     target = ZERO_ADDRESS
#     with pytest.raises(ape.exceptions.ContractLogicError) as exc_info:
#         token.addMinter(target, sender=admin)
#     assert exc_info.value.args[0] == "Cannot add zero address as minter."


def test_burn(token, admin):
    """
    Burn/Send amount of tokens to ZERO Address.
    """
    totalSupply = token.totalSupply()
    assert totalSupply == 1000

    owner_balance = token.balanceOf(admin)
    assert owner_balance == 1000

    tx = token.burn(420, sender=admin)

    # logs = list(tx.decode_logs(token.Transfer))
    # assert len(logs) == 1
    # assert logs[0].sender == admin
    # assert logs[0].amount == 420

    owner_balance = token.balanceOf(admin)
    assert owner_balance == 580

    totalSupply = token.totalSupply()
    assert totalSupply == 580


def test_permit(chain, token, admin, me, Permit):
    """
    Validate permit method for incorrect ownership, values, and timing
    """
    amount = 100
    nonce = token.nonces(admin)
    deadline = chain.pending_timestamp + 60
    assert token.allowance(admin, me) == 0
    permit = Permit(admin.address, me.address, amount, nonce, deadline)
    signature = admin.sign_message(permit.signable_message).encode_rsv()

    with boa.reverts():
        token.permit(me, me, amount, deadline, signature, sender=me)
    with boa.reverts():
        token.permit(admin, admin, amount, deadline, signature, sender=me)
    with boa.reverts():
        token.permit(admin, me, amount + 1, deadline, signature, sender=me)
    with boa.reverts():
        token.permit(admin, me, amount, deadline + 1, signature, sender=me)

    token.permit(admin, me, amount, deadline, signature, sender=me)

    assert token.allowance(admin, me) == 100