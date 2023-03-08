TODO:

-   copy project structure of https://github.com/curvefi/curve-stablecoin with boa testing
-   https://curve.readthedocs.io/guide-code-style.html

## Installation
Make sure `python --version` emits >= 3.10.0
```bash
   pip install -r prod-requirements.txt
   pip install -r dev-requirements.txt
   ape plugins install .
   forge install
```

## Development

To get a feel for the contracts you should start plalying around with them in boa.

```
$ [insert your python virtual environment command here]

$ python

$ >>>>> import boa

# cache source compilations across sessions
$ >>>>> boa.interpret.set_cache_dir()

# allow gas profiling e.g. pool.line_profile().summary()
$ >>>>> boa.env.enable_gas_profiling()

# setup contracts
$ >>>>> admin = boa.env.generate_address()
$ >>>>> asset = boa.load('tests/mocks/MockERC20.vy', 'An Asset To Lend', 'LEND', 18)
$ >>>>> pool = boa.load('contracts/DebtDAOPool.vy', admin, asset, 'Dev Testing', 'TEST', [0,0,0,0,0,0])

$ >>>>> asset.decimals()
$ >>>>> pool.decimals()

# start using your contracts
$ >>>>> mint_amount = 100
$ >>>>> asset.mint(admin, mint_amount, sender=admin)
$ >>>>> asset.approve(pool, mint_amount, sender=admin)
$ >>>>> pool.deposit(mint_amount, admin, sender=admin)
```

## Boa dev notes

### Snippets

Claim revenue

```
# give owner free fees to claim
$ >>>>> pool.eval('self.accrued_fees = 10')
 # create shares so owner can claim
$ >>>>> pool.eval(f'self.balances[self] = 100')
# claim as owner
$ >>>>> pool.claim_rev(pool.address, 10, sender=admin)
$ >>>>> pool.line_profile().summary()
```
### Tips

1. Must redeploy contracts with `boa.load` for code changes to take affect.
2. Dont overwrite variables when redeploying in the REPL.
   This sequenece of commands will fail because the `asset` you are minting and approving to is different han the `asset` in the Pool contract.

```
$ >>>>> asset = boa.load('tests/mocks/MockERC20.vy', 'An Asset To Lend', 'LEND', 18)
$ >>>>> pool = boa.load('contracts/DebtDAOPool.vy', admin, asset, 'Dev Testing', 'TEST', [0,0,0,0,0,0])

$ >>>>> asset = boa.load('tests/mocks/MockERC20.vy', 'An Asset To Lend', 'LEND', 18)

$ >>>>> asset.mint(admin, mint_amount, sender=admin)
$ >>>>> asset.approve(pool, mint_amount, sender=admin)
$ >>>>> pool.deposit(mint_amount, admin, sender=admin)
$ >>>>> boa.env.time_travel(seconds=1000)
$ >>>>> pool.unlock_profit()
```


## Testing
Because Ape and Boa are both experimetal software and take long af to run tests, we still use Foundry as our primary testing suite to ensure no bugs in our python tech stack. We maintain a full test suite in Ape and Boa because 1) we prefer it 2) to help find bugs and improve the software. Both testing suites should have full testing parity


`forge test -vvv`
`pytest`

# Docs

install Mermaid CLI
`https://github.com/mermaid-js/mermaid-cli`


`export $MERMAID_FILE_PATH="./docs/ChikkinPonziSystem"; mmdc -i $MERMAID_FILE_PATH.mmd -o $MERMAID_FILE_PATH.svg -t dark -b transparent && open $MERMAID_FILE_PATH.svg`
