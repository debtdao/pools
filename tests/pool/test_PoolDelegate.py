import boa
import boa
import ape
# from boa.vyper.contract import BoaError
# from hypothesis import given, settings
# from hypothesis import strategies as st
# from hypothesis.stateful import RuleBasedStateMachine, run_state_machine_as_test, rule, invariant
# from datetime import timedelta



# TODO for debt dao
# @given(
#     oracle_price=st.integers(min_value=2000 * 10**18, max_value=4000 * 10**18),
#     n1=st.integers(min_value=1, max_value=50),
#     dn=st.integers(min_value=0, max_value=49),
#     deposit_amount=st.integers(min_value=10**12, max_value=10**25),
#     init_trade_frac=st.floats(min_value=0.0, max_value=1.0),
#     p_frac=st.floats(min_value=0.1, max_value=10)
# )
# @settings(max_examples=500, deadline=timedelta(seconds=1000))
# def test_owner_fees_burned_on_impairment(
#     price_oracle, amm, accounts, collateral_token, borrowed_token, admin,
#     oracle_price, n1, dn, deposit_amount, init_trade_frac, p_frac
# ):
#     user = accounts[0]
#     with boa.env.prank(admin):
#         amm.set_fee(0)
#         price_oracle.set_price(oracle_price)
   