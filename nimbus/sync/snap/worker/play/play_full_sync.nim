# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  chronicles,
  chronos,
  eth/p2p,
  ../../../misc/[best_pivot, block_queue],
  "../../.."/[protocol, sync_desc, types],
  "../.."/[range_desc, worker_desc],
  ../db/[snapdb_desc, snapdb_persistent],
  ".."/[pivot, ticker],
  play_desc

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template ignoreException(info: static[string]; code: untyped) =
  try:
    code
  except CatchableError as e:
    error "Exception at " & info & ":", name=($e.name), msg=(e.msg)

proc tickerUpdater(ctx: SnapCtxRef): TickerFullStatsUpdater =
  result = proc: TickerFullStats =
    var stats: BlockQueueStats
    ctx.pool.bCtx.blockQueueStats(stats)

    TickerFullStats(
      topPersistent:   stats.topAccepted,
      nextStaged:      stats.nextStaged,
      nextUnprocessed: stats.nextUnprocessed,
      nStagedQueue:    stats.nStagedQueue,
      reOrg:           stats.reOrg)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc processStaged(buddy: SnapBuddyRef): bool =
  ## Fetch a work item from the `staged` queue an process it to be
  ## stored on the persistent block chain.
  let
    ctx {.used.} = buddy.ctx
    peer = buddy.peer
    chainDb = buddy.ctx.chain.db
    chain = buddy.ctx.chain
    bq = buddy.only.bQueue

    # Get a work item, a list of headers + bodies
    wi = block:
      let rc = bq.blockQueueFetchStaged()
      if rc.isErr:
        return false
      rc.value

    #startNumber = wi.headers[0].blockNumber -- unused

  # Store in persistent database
  try:
    if chain.persistBlocks(wi.headers, wi.bodies) == ValidationResult.OK:
      bq.blockQueueAccept(wi)
      return true
  except CatchableError as e:
    error "Storing persistent blocks failed", peer, range=($wi.blocks),
      name=($e.name), msg=(e.msg)

  # Something went wrong. Recycle work item (needs to be re-fetched, anyway)
  let
    parentHash = wi.headers[0].parentHash
  try:
    # Check whether hash of the first block is consistent
    var parent: BlockHeader
    if chainDb.getBlockHeader(parentHash, parent):
      # First block parent is ok, so there might be other problems. Re-fetch
      # the blocks from another peer.
      trace "Storing persistent blocks failed", peer, range=($wi.blocks)
      bq.blockQueueRecycle(wi)
      buddy.ctrl.zombie = true
      return false
  except CatchableError as e:
    error "Failed to access parent blocks", peer,
      blockNumber=wi.headers[0].blockNumber.toStr, name=($e.name), msg=e.msg

  # Parent block header problem, so we might be in the middle of a re-org.
  # Set single mode backtrack following the offending parent hash.
  bq.blockQueueBacktrackFrom(wi)
  buddy.ctrl.multiOk = false

  if wi.topHash.isNone:
    # Assuming that currently staged entries are on the wrong branch
    bq.blockQueueRecycleStaged()
    notice "Starting chain re-org backtrack work item", peer, range=($wi.blocks)
  else:
    # Leave that block range in the staged list
    trace "Resuming chain re-org backtrack work item", peer, range=($wi.blocks)
    discard

  return false

# ------------------------------------------------------------------------------
# Private functions, full sync admin handlers
# ------------------------------------------------------------------------------

proc fullSyncSetup(ctx: SnapCtxRef) =
  let blockNum = if ctx.pool.fullPivot.isNil: ctx.pool.pivotTable.topNumber
                 else: ctx.pool.fullPivot.stateHeader.blockNumber

  ctx.pool.bCtx = BlockQueueCtxRef.init(blockNum + 1)
  ctx.pool.bPivot = BestPivotCtxRef.init(rng=ctx.pool.rng, minPeers=0)
  ctx.pool.ticker.init(cb = ctx.tickerUpdater())

proc fullSyncRelease(ctx: SnapCtxRef) =
  discard


proc fullSyncStart(buddy: SnapBuddyRef): bool =
  let
    ctx = buddy.ctx
    peer = buddy.peer

  if peer.supports(protocol.eth) and
     peer.state(protocol.eth).initialized:

    buddy.only.bQueue = BlockQueueWorkerRef.init(
      ctx.pool.bCtx, buddy.ctrl, peer)
    buddy.only.bPivot = BestPivotWorkerRef.init(
      ctx.pool.bPivot, buddy.ctrl, buddy.peer)

    ctx.pool.ticker.startBuddy()
    buddy.ctrl.multiOk = false # confirm default mode for soft restart
    return true

proc fullSyncStop(buddy: SnapBuddyRef) =
  buddy.only.bPivot.clear()
  buddy.ctx.pool.ticker.stopBuddy()

# ------------------------------------------------------------------------------
# Private functions, full sync action handlers
# ------------------------------------------------------------------------------

proc fullSyncDaemon(ctx: SnapCtxRef) {.async.} =
  ctx.daemon = false


proc fullSyncPool(buddy: SnapBuddyRef, last: bool; laps: int): bool =
  let
    ctx = buddy.ctx
    env = ctx.pool.fullPivot

  # Take over soft restart after switch to full sync mode.
  # This process needs to be applied to all buddy peers.
  if not env.isNil:
    # Soft start all peers on the second lap.
    ignoreException("fullSyncPool"):
      if not ctx.playMethod.start(buddy):
        # Start() method failed => wait for another peer
        buddy.ctrl.stopped = true
    if last:
      trace "Soft full sync restart done", peer=buddy.peer, last, laps,
        pivot=env.stateHeader.blockNumber.toStr,
        mode=ctx.pool.syncMode.active, state= buddy.ctrl.state

      # Store pivot as parent hash in database
      ctx.pool.snapDb.kvDb.persistentBlockHeaderPut env.stateHeader

      # Instead of genesis.
      ctx.chain.com.startOfHistory = env.stateHeader.blockHash

      # Reset so that this actuin would not be triggered, again
      ctx.pool.fullPivot = nil
    return false # do stop magically when looping over peers is exhausted

  # Mind the gap, fill in if necessary (function is peer independent)
  buddy.only.bQueue.blockQueueGrout()
  true # Stop after running once regardless of peer


proc fullSyncSingle(buddy: SnapBuddyRef) {.async.} =
  let
    pv = buddy.only.bPivot
    bq = buddy.only.bQueue
    bNum = bq.bestNumber.get(otherwise = bq.topAccepted + 1)

  # Negotiate in order to derive the pivot header from this `peer`.
  if await pv.pivotNegotiate(some(bNum)):
    # Update/activate `bestNumber` from the pivot header
    bq.bestNumber = some(pv.pivotHeader.value.blockNumber)
    buddy.ctrl.multiOk = true
    when extraTraceMessages:
      trace "Full sync pivot accepted", peer=buddy.peer,
        minNumber=bNum.toStr, bestNumber=bq.bestNumber.unsafeGet.toStr
    return

  if buddy.ctrl.stopped:
    when extraTraceMessages:
      trace "Full sync single mode stopped", peer=buddy.peer
    return # done with this buddy

  # Without waiting, this function repeats every 50ms (as set with the constant
  # `sync_sched.execLoopTimeElapsedMin`.)
  await sleepAsync 300.milliseconds


proc fullSyncMulti(buddy: SnapBuddyRef): Future[void] {.async.} =
  ## Full sync processing
  let
    ctx = buddy.ctx
    bq = buddy.only.bQueue

  # Fetch work item
  let rc = await bq.blockQueueWorker()
  if rc.isErr:
    if rc.error == StagedQueueOverflow:
      # Mind the gap: Turn on pool mode if there are too may staged items.
      ctx.poolMode = true
    else:
      trace "Full sync error", peer=buddy.peer, error=rc.error
      return

  # Update persistent database
  while buddy.processStaged() and not buddy.ctrl.stopped:
    trace "Full sync multi processed", peer=buddy.peer
    # Allow thread switch as `persistBlocks()` might be slow
    await sleepAsync(10.milliseconds)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc playFullSyncSpecs*: PlaySyncSpecs =
  ## Return full sync handler environment
  PlaySyncSpecs(
    setup:   fullSyncSetup,
    release: fullSyncRelease,
    start:   fullSyncStart,
    stop:    fullSyncStop,
    pool:    fullSyncPool,
    daemon:  fullSyncDaemon,
    single:  fullSyncSingle,
    multi:   fullSyncMulti)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
