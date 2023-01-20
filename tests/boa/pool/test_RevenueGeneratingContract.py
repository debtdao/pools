# TODO check tests against most recent 

# Table of Contents

# Role ACL and state changes
# 1. only {role} can set_{role}
# 2. only pending_{role} can call accept_{role}
# 3. current {role} cant call accept_{role}
# 4. {role} cant call accept_{role}
# 5. no one can accept_{role} if pending_{role} is null
# 6. no one can set_{role} if {role} is null

# Control of revenue stream
# 1. rev_recipient can claim_rev
# 1. non rev_recipient cant claim_rev
# 1. self.owner cant claim_rev
# 2. (invariant) all self.owner rev is claimable by self.rev_recipient
# 3. (invariant) claimable rev == sum of self.owner fees events emitted
# 4. emits revenue event even if no revenue generated
# 5. (invariant) max_uint claim_rev is claimable_rev
# 6. cant claim more than claimable_rev from claim_rev
# 9. claim rev should fail if push pa yments implemented
# 11. claim_rev should not fail if payments claimable by rev_recipient
# 7. can claim_rev up to claimable_rev 
# 7. if accept_ivoice doesnt revert, it must return IRevenueGenerator.payInvoice.selector 
# 13. emit RevenueGenerated if 0 rev