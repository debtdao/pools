import math
from ..conftest import POOL_PRICE_DECIMALS, MAX_UINT

def _calc_price(assets: int, shares: int) -> int:
    if assets == 0:
        return POOL_PRICE_DECIMALS

    return math.floor(math.floor(assets * POOL_PRICE_DECIMALS) / max(1, shares))

# algo v2 

def _to_shares(assets: int, price: int) -> int:
    if price == 0:
        return 0
    
    return math.floor(math.floor(assets * POOL_PRICE_DECIMALS) / max(1, price))
        

def _to_assets(shares: int, price: int) -> int:
    if price == 0:
        return 0

    return math.floor(math.floor(shares * price) / POOL_PRICE_DECIMALS)



# algo v1
# def _to_shares(assets: int, price: int, max_val: int = MAX_UINT) -> int:
#     if price == 0:
#         return 1

#     return math.floor(min(math.floor(math.floor(assets * POOL_PRICE_DECIMALS) / price), max_val))
        
# def _to_assets(shares: int, price: int, max_val: int = MAX_UINT) -> int:
#     if price == 0:
#         return 1

#     return math.floor(min(math.floor(math.floor(shares * price) / POOL_PRICE_DECIMALS), max_val))

