# import pytest
# from ape import Contract
# from eip712.messages import EIP712Message

# boa.interpret.set_cache_dir()
# boa.reset_env()

# boa/ape test references
# https://github.com/ApeAcademy/ERC20/blob/main/%7B%7Bcookiecutter.project_name%7D%7D/tests/conftest.py

# get token, user balances and pass on. 
# used to test mintin, burning, transfering, etc.

# @given
# def test_token_balances()


# @pytest.fixture(scope="module")
# def Permit(chain, token):
#     class Permit(EIP712Message):
#         _name_  = "Lending Token" #: "string"
#         _version_  ="1.0" #: "string"
#         _chainId_  = chain.chain_id #: "uint256"
#         _verifyingContract_  = token.address #: "address"

#         # owner  : "address"
#         # spender  : "address"
#         # value  : "uint256"
#         # nonce  : "uint256"
#         # deadline  : "uint256"

#     return Permit


# @pytest.fixture(scope="module")
# def owner(accounts):
#     return accounts[0]

# @pytest.fixture(scope="module")
# def receiver(accounts):
#     return accounts[1]

# @pytest.fixture(scope="module")
# def asset(token):
#     return Contract(token.asset())

# @pytest.fixture(scope="module")
# def token(owner, project, token):
#     # todo change to `ape.reverts():` ?
#     try:
#         return owner.deploy(project.Token, token.asset())
#     finally:
#         return owner.deploy(project.Token, token)