TODO:
- copy project structure of https://github.com/curvefi/curve-stablecoin with boa testing
- https://curve.readthedocs.io/guide-code-style.html


## installation

```bash
 pip install -r ape-requirements.txt   
 pip install -r boa-requirements.txt   
ape plugins install .
```
## Testing
`ape test --network=ethereum:local:foundry --trace --cache-clear --gas -v DEBUG`