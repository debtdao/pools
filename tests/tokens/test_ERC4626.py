# TODO Ask ChatGPT to generate test cases in vyper

# TEST all 4626 unit tests on preview functions. then compare preview func to actual action func 
# (only diff between preview and action is side effects - state and events 

# preview functions - right share price return value
# preview functions - proper fees calculated
# preview -> action equality
# mint/redeem + deposit/withdraw equality (incl fees)

# TEST all events properly emitted 
# deposit/withdraw
# fee events


# TEST invariants
# total supply with mint/burn
# share price changes (+/-) 
# share price based on supply/assets

# https://github.com/fubuloubu/ERC4626/blob/main/tests/test_methods.py