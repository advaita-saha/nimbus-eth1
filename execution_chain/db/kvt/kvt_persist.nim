# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- Transaction save helper
## ======================================
##
{.push raises: [].}

import
  ./[kvt_desc, kvt_tx_frame]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc persist*(
    db: KvtDbRef;
    batch: PutHdlRef;
    txFrame: KvtTxRef
      ) =
  db.txFramePersist(batch, txFrame)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
