

# boa.interpret.set_cache_dir()
# boa.reset_env()

# boa/ape test references
# https://github.com/ApeAcademy/ERC20/blob/main/%7B%7Bcookiecutter.project_name%7D%7D/tests/conftest.py

# get token, user balances and pass on. 
# used to test mintin, burning, transfering, etc.

# @given
# def test_token_balances()




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