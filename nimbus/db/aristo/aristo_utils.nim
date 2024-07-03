# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Handy Helpers
## ==========================
##
{.push raises: [].}

import
  std/sequtils,
  eth/common,
  results,
  "."/[aristo_constants, aristo_desc, aristo_get, aristo_hike, aristo_layers]

# ------------------------------------------------------------------------------
# Public functions, converters
# ------------------------------------------------------------------------------

proc toNode*(
    vtx: VertexRef;                    # Vertex to convert
    db: AristoDbRef;                   # Database, top layer
    stopEarly = true;                  # Full list of missing links if `false`
    beKeyOk = true;                    # Allow fetching DB backend keys
      ): Result[NodeRef,seq[VertexID]] =
  ## Convert argument the vertex `vtx` to a node type. Missing Merkle hash
  ## keys are searched for on the argument database `db`.
  ##
  ## On error, at least the vertex ID of the first missing Merkle hash key is
  ## returned. If the argument `stopEarly` is set `false`, all missing Merkle
  ## hash keys are returned.
  ##
  ## In the argument `beKeyOk` is set `false`, keys for node links are accepted
  ## only from the cache layer. This does not affect a link key for a payload
  ## storage root.
  ##
  proc getKey(db: AristoDbRef; vid: VertexID; beOk: bool): HashKey =
    block body:
      let key = db.layersGetKey(vid).valueOr:
        break body
      if key.isValid:
        return key
      else:
        return VOID_HASH_KEY
    if beOk:
      let rc = db.getKeyBE vid
      if rc.isOk:
        return rc.value
    VOID_HASH_KEY

  case vtx.vType:
  of Leaf:
    let node = NodeRef(vType: Leaf, lPfx: vtx.lPfx, lData: vtx.lData)
    # Need to resolve storage root for account leaf
    if vtx.lData.pType == AccountData:
      let vid = vtx.lData.stoID
      if vid.isValid:
        let key = db.getKey vid
        if not key.isValid:
          return err(@[vid])
        node.key[0] = key
    return ok node

  of Branch:
    let node = NodeRef(vType: Branch, bVid: vtx.bVid)
    var missing: seq[VertexID]
    for n in 0 .. 15:
      let vid = vtx.bVid[n]
      if vid.isValid:
        let key = db.getKey(vid, beOk=beKeyOk)
        if key.isValid:
          node.key[n] = key
        elif stopEarly:
          return err(@[vid])
        else:
          missing.add vid
    if 0 < missing.len:
      return err(missing)
    return ok node

  of Extension:
    let
      vid = vtx.eVid
      key = db.getKey(vid, beOk=beKeyOk)
    if not key.isValid:
      return err(@[vid])
    let node = NodeRef(vType: Extension, ePfx: vtx.ePfx, eVid: vid)
    node.key[0] = key
    return ok node


iterator subVids*(vtx: VertexRef): VertexID =
  ## Returns the list of all sub-vertex IDs for the argument `vtx`.
  case vtx.vType:
  of Leaf:
    if vtx.lData.pType == AccountData:
      let vid = vtx.lData.stoID
      if vid.isValid:
        yield vid
  of Branch:
    for vid in vtx.bVid:
      if vid.isValid:
        yield vid
  of Extension:
    yield vtx.eVid

# ---------------------

proc updateAccountForHasher*(
    db: AristoDbRef;                   # Database
    hike: Hike;                        # Return value from `retrieveStorageID()`
      ) =
  ## The argument `hike` is used to mark/reset the keys along the implied
  ## vertex path for being re-calculated.
  ##
  # Clear Merkle keys so that `hasify()` can calculate the re-hash forest/tree
  for w in hike.legs.mapIt(it.wp.vid):
    db.layersResKey(hike.root, w)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
