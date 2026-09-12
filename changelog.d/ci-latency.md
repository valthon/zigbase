### Internal
- Split CI feature, contract, code-generation and performance checks into independent lanes; parallelize isolated upload tests and remove growing local-cache transfers from the critical path while preserving required-check coverage.
