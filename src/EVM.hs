{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImplicitParams #-}

module EVM where

import Prelude hiding (exponent)

import Optics.Core
import Optics.State
import Optics.State.Operators
import Optics.Zoom
import Optics.Operators.Unsafe

import EVM.ABI
import EVM.Expr (readStorage, writeStorage, readByte, readWord, writeWord,
  writeByte, bufLength, indexWord, litAddr, readBytes, word256At, copySlice, wordToAddr)
import EVM.Expr qualified as Expr
import EVM.FeeSchedule (FeeSchedule (..))
import EVM.Op
import EVM.Precompiled qualified
import EVM.Solidity
import EVM.Types
import EVM.Sign qualified
import EVM.Concrete qualified as Concrete

import Control.Monad.ST (ST)
import Control.Monad.State.Strict hiding (state)
import Data.Bits (FiniteBits, countLeadingZeros, finiteBitSize)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy (fromStrict)
import Data.ByteString.Lazy qualified as LS
import Data.ByteString.Char8 qualified as Char8
import Data.Foldable (toList)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, fromJust, isJust)
import Data.Set (insert, member, fromList)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Text (unpack, pack)
import Data.Text.Encoding (decodeUtf8)
import Data.Tree
import Data.Tree.Zipper qualified as Zipper
import Data.Typeable
import Data.Vector qualified as V
import Data.Vector.Storable qualified as SV
import Data.Vector.Storable.Mutable qualified as SV
import Data.Vector.Unboxed qualified as VUnboxed
import Data.Vector.Unboxed.Mutable qualified as VUnboxed.Mutable
import Data.Word (Word8, Word32, Word64)
import Witch (into, tryFrom, unsafeInto)

import Crypto.Hash (Digest, SHA256, RIPEMD160)
import Crypto.Hash qualified as Crypto
import Crypto.Number.ModArithmetic (expFast)

blankState :: ST s (FrameState s)
blankState = do
  memory <- ConcreteMemory <$> VUnboxed.Mutable.new 0
  pure $ FrameState
    { contract     = LitAddr 0
    , codeContract = LitAddr 0
    , code         = RuntimeCode (ConcreteRuntimeCode "")
    , pc           = 0
    , stack        = mempty
    , memory
    , memorySize   = 0
    , calldata     = mempty
    , callvalue    = Lit 0
    , caller       = LitAddr 0
    , gas          = 0
    , returndata   = mempty
    , static       = False
    }

-- | An "external" view of a contract's bytecode, appropriate for
-- e.g. @EXTCODEHASH@.
bytecode :: Getter Contract (Maybe (Expr Buf))
bytecode = #code % to f
  where f (InitCode _ _) = Just mempty
        f (RuntimeCode (ConcreteRuntimeCode bs)) = Just $ ConcreteBuf bs
        f (RuntimeCode (SymbolicRuntimeCode ops)) = Just $ Expr.fromList ops
        f (UnknownCode _) = Nothing

-- * Data accessors

currentContract :: VM s -> Maybe Contract
currentContract vm =
  Map.lookup vm.state.codeContract vm.env.contracts

-- * Data constructors

makeVm :: VMOpts -> ST s (VM s)
makeVm o = do
  let txaccessList = o.txAccessList
      txorigin = o.origin
      txtoAddr = o.address
      initialAccessedAddrs = fromList $
           [txorigin, txtoAddr, o.coinbase]
        ++ (fmap LitAddr [1..9])
        ++ (Map.keys txaccessList)
      initialAccessedStorageKeys = fromList $ foldMap (uncurry (map . (,))) (Map.toList txaccessList)
      touched = if o.create then [txorigin] else [txorigin, txtoAddr]
  memory <- ConcreteMemory <$> VUnboxed.Mutable.new 0
  pure $ VM
    { result = Nothing
    , frames = mempty
    , tx = TxState
      { gasprice = o.gasprice
      , gaslimit = o.gaslimit
      , priorityFee = o.priorityFee
      , origin = txorigin
      , toAddr = txtoAddr
      , value = o.value
      , substate = SubState mempty touched initialAccessedAddrs initialAccessedStorageKeys mempty
      , isCreate = o.create
      , txReversion = Map.fromList ((o.address,o.contract):o.otherContracts)
      }
    , logs = []
    , traces = Zipper.fromForest []
    , block = block
    , state = FrameState
      { pc = 0
      , stack = mempty
      , memory
      , memorySize = 0
      , code = o.contract.code
      , contract = o.address
      , codeContract = o.address
      , calldata = fst o.calldata
      , callvalue = o.value
      , caller = o.caller
      , gas = o.gas
      , returndata = mempty
      , static = False
      }
    , env = env
    , cache = cache
    , burned = 0
    , constraints = snd o.calldata
    , keccakEqs = mempty
    , iterations = mempty
    , config = RuntimeConfig
      { allowFFI = o.allowFFI
      , overrideCaller = Nothing
      , baseState = o.baseState
      }
    , forks = Seq.singleton (ForkState env block cache "")
    , currentFork = 0
    }
    where
    env = Env
      { chainId = o.chainId
      , contracts = Map.fromList ((o.address,o.contract):o.otherContracts)
      , freshAddresses = 0
      }
    block = Block
      { coinbase = o.coinbase
      , timestamp = o.timestamp
      , number = o.number
      , prevRandao = o.prevRandao
      , maxCodeSize = o.maxCodeSize
      , gaslimit = o.blockGaslimit
      , baseFee = o.baseFee
      , schedule = o.schedule
      }
    cache = Cache mempty mempty

-- | Initialize an abstract contract with unknown code
unknownContract :: Expr EAddr -> Contract
unknownContract addr = Contract
  { code        = UnknownCode addr
  , storage     = AbstractStore addr
  , origStorage = AbstractStore addr
  , balance     = Balance addr
  , nonce       = Nothing
  , codehash    = hashcode (UnknownCode addr)
  , opIxMap     = mempty
  , codeOps     = mempty
  , external    = False
  }

-- | Initialize an abstract contract with known code
abstractContract :: ContractCode -> Expr EAddr -> Contract
abstractContract code addr = Contract
  { code        = code
  , storage     = AbstractStore addr
  , origStorage = AbstractStore addr
  , balance     = Balance addr
  , nonce       = if isCreation code then Just 1 else Just 0
  , codehash    = hashcode code
  , opIxMap     = mkOpIxMap code
  , codeOps     = mkCodeOps code
  , external    = False
  }

-- | Initialize an empty contract without code
emptyContract :: Contract
emptyContract = initialContract (RuntimeCode (ConcreteRuntimeCode ""))

-- | Initialize empty contract with given code
initialContract :: ContractCode -> Contract
initialContract code = Contract
  { code        = code
  , storage     = ConcreteStore mempty
  , origStorage = ConcreteStore mempty
  , balance     = Lit 0
  , nonce       = if isCreation code then Just 1 else Just 0
  , codehash    = hashcode code
  , opIxMap     = mkOpIxMap code
  , codeOps     = mkCodeOps code
  , external    = False
  }

isCreation :: ContractCode -> Bool
isCreation = \case
  InitCode _ _  -> True
  RuntimeCode _ -> False
  UnknownCode _ -> False

-- * Opcode dispatch (exec1)

-- | Update program counter
next :: (?op :: Word8) => EVM s ()
next = modifying (#state % #pc) (+ (opSize ?op))

-- | Executes the EVM one step
exec1 :: EVM s ()
exec1 = do
  vm <- get

  let
    -- Convenient aliases
    stk  = vm.state.stack
    self = vm.state.contract
    this = fromMaybe (internalError "state contract") (Map.lookup self vm.env.contracts)

    fees@FeeSchedule {..} = vm.block.schedule

    doStop = finishFrame (FrameReturned mempty)

    litSelf = maybeLitAddr self

  if isJust litSelf && (fromJust litSelf) > 0x0 && (fromJust litSelf) <= 0x9 then do
    -- call to precompile
    let ?op = 0x00 -- dummy value
    case bufLength vm.state.calldata of
      Lit calldatasize -> do
          copyBytesToMemory vm.state.calldata (Lit calldatasize) (Lit 0) (Lit 0)
          executePrecompile (fromJust litSelf) vm.state.gas 0 calldatasize 0 0 []
          vmx <- get
          case vmx.state.stack of
            x:_ -> case x of
              Lit 0 ->
                fetchAccount self $ \_ -> do
                  touchAccount self
                  vmError PrecompileFailure
              Lit _ ->
                fetchAccount self $ \_ -> do
                  touchAccount self
                  out <- use (#state % #returndata)
                  finishFrame (FrameReturned out)
              e -> partial $
                     UnexpectedSymbolicArg vmx.state.pc "precompile returned a symbolic value" (wrap [e])
            _ ->
              underrun
      e -> partial $
             UnexpectedSymbolicArg vm.state.pc "cannot call precompiles with symbolic data" (wrap [e])

  else if vm.state.pc >= opslen vm.state.code
    then doStop

    else do
      let ?op = case vm.state.code of
                  UnknownCode _ -> internalError "Cannot execute unknown code"
                  InitCode conc _ -> BS.index conc vm.state.pc
                  RuntimeCode (ConcreteRuntimeCode bs) -> BS.index bs vm.state.pc
                  RuntimeCode (SymbolicRuntimeCode ops) ->
                    fromMaybe (internalError "could not analyze symbolic code") $
                      maybeLitByte $ ops V.! vm.state.pc

      case getOp (?op) of

        OpPush0 -> do
          limitStack 1 $
            burn g_base $ do
              next
              pushSym (Lit 0)

        OpPush n' -> do
          let n = into n'
              !xs = case vm.state.code of
                UnknownCode _ -> internalError "Cannot execute unknown code"
                InitCode conc _ -> Lit $ word $ padRight n $ BS.take n (BS.drop (1 + vm.state.pc) conc)
                RuntimeCode (ConcreteRuntimeCode bs) -> Lit $ word $ BS.take n $ BS.drop (1 + vm.state.pc) bs
                RuntimeCode (SymbolicRuntimeCode ops) ->
                  let bytes = V.take n $ V.drop (1 + vm.state.pc) ops
                  in readWord (Lit 0) $ Expr.fromList $ padLeft' 32 bytes
          limitStack 1 $
            burn g_verylow $ do
              next
              pushSym xs

        OpDup i ->
          case preview (ix (into i - 1)) stk of
            Nothing -> underrun
            Just y ->
              limitStack 1 $
                burn g_verylow $ do
                  next
                  pushSym y

        OpSwap i ->
          if length stk < (into i) + 1
            then underrun
            else
              burn g_verylow $ do
                next
                zoom (#state % #stack) $ do
                  assign (ix 0) (stk ^?! ix (into i))
                  assign (ix (into i)) (stk ^?! ix 0)

        OpLog n ->
          notStatic $
          case stk of
            (xOffset':xSize':xs) ->
              if length xs < (into n)
              then underrun
              else
                forceConcrete2 (xOffset', xSize') "LOG" $ \(xOffset, xSize) -> do
                    bytes <- readMemory xOffset' xSize'
                    let (topics, xs') = splitAt (into n) xs
                        logs'         = (LogEntry (WAddr self) bytes topics) : vm.logs
                    case (tryFrom xSize) of
                      (Right sz) ->
                        burn (g_log + g_logdata * sz + (into n) * g_logtopic) $
                          accessMemoryRange xOffset xSize $ do
                            traceTopLog logs'
                            next
                            assign (#state % #stack) xs'
                            assign #logs logs'
                      _ -> vmError IllegalOverflow
            _ ->
              underrun

        OpStop -> doStop

        OpAdd -> stackOp2 g_verylow Expr.add
        OpMul -> stackOp2 g_low Expr.mul
        OpSub -> stackOp2 g_verylow Expr.sub

        OpDiv -> stackOp2 g_low Expr.div

        OpSdiv -> stackOp2 g_low Expr.sdiv

        OpMod -> stackOp2 g_low Expr.mod

        OpSmod -> stackOp2 g_low Expr.smod
        OpAddmod -> stackOp3 g_mid Expr.addmod
        OpMulmod -> stackOp3 g_mid Expr.mulmod

        OpLt -> stackOp2 g_verylow Expr.lt
        OpGt -> stackOp2 g_verylow Expr.gt
        OpSlt -> stackOp2 g_verylow Expr.slt
        OpSgt -> stackOp2 g_verylow Expr.sgt

        OpEq -> stackOp2 g_verylow Expr.eq
        OpIszero -> stackOp1 g_verylow Expr.iszero

        OpAnd -> stackOp2 g_verylow Expr.and
        OpOr -> stackOp2 g_verylow Expr.or
        OpXor -> stackOp2 g_verylow Expr.xor
        OpNot -> stackOp1 g_verylow Expr.not

        OpByte -> stackOp2 g_verylow (\i w -> Expr.padByte $ Expr.indexWord i w)

        OpShl -> stackOp2 g_verylow Expr.shl
        OpShr -> stackOp2 g_verylow Expr.shr
        OpSar -> stackOp2 g_verylow Expr.sar

        -- more accurately refered to as KECCAK
        OpSha3 ->
          case stk of
            xOffset':xSize':xs ->
              forceConcrete xOffset' "sha3 offset must be concrete" $
                \xOffset -> forceConcrete xSize' "sha3 size must be concrete" $ \xSize ->
                  burn (g_sha3 + g_sha3word * ceilDiv (unsafeInto xSize) 32) $
                    accessMemoryRange xOffset xSize $ do
                      hash <- readMemory xOffset' xSize' >>= \case
                        ConcreteBuf bs -> do
                          let hash' = keccak' bs
                          eqs <- use #keccakEqs
                          assign #keccakEqs $
                            PEq (Lit hash') (Keccak (ConcreteBuf bs)):eqs
                          pure $ Lit hash'
                        buf -> pure $ Keccak buf
                      next
                      assign (#state % #stack) (hash : xs)
            _ -> underrun

        OpAddress ->
          limitStack 1 $
            burn g_base (next >> pushAddr self)

        OpBalance ->
          case stk of
            x:xs -> forceAddr x "BALANCE" $ \a ->
              accessAndBurn a $
                fetchAccount a $ \c -> do
                  next
                  assign (#state % #stack) xs
                  pushSym c.balance
            [] ->
              underrun

        OpOrigin ->
          limitStack 1 . burn g_base $
            next >> pushAddr vm.tx.origin

        OpCaller ->
          limitStack 1 . burn g_base $
            next >> pushAddr vm.state.caller

        OpCallvalue ->
          limitStack 1 . burn g_base $
            next >> pushSym vm.state.callvalue

        OpCalldataload -> stackOp1 g_verylow $
          \ind -> Expr.readWord ind vm.state.calldata

        OpCalldatasize ->
          limitStack 1 . burn g_base $
            next >> pushSym (bufLength vm.state.calldata)

        OpCalldatacopy ->
          case stk of
            xTo':xFrom:xSize':xs ->
              forceConcrete2 (xTo', xSize') "CALLDATACOPY" $
                \(xTo, xSize) ->
                  burn (g_verylow + g_copy * ceilDiv (unsafeInto xSize) 32) $
                    accessMemoryRange xTo xSize $ do
                      next
                      assign (#state % #stack) xs
                      copyBytesToMemory vm.state.calldata xSize' xFrom xTo'
            _ -> underrun

        OpCodesize ->
          limitStack 1 . burn g_base $
            next >> pushSym (codelen vm.state.code)

        OpCodecopy ->
          case stk of
            memOffset':codeOffset:n':xs ->
              forceConcrete2 (memOffset', n') "CODECOPY" $
                \(memOffset,n) -> do
                  case toWord64 n of
                    Nothing -> vmError IllegalOverflow
                    Just n'' ->
                      if n'' <= ( (maxBound :: Word64) - g_verylow ) `div` g_copy * 32 then
                        burn (g_verylow + g_copy * ceilDiv (unsafeInto n) 32) $
                          accessMemoryRange memOffset n $ do
                            next
                            assign (#state % #stack) xs
                            case toBuf vm.state.code of
                              Just b -> copyBytesToMemory b n' codeOffset memOffset'
                              Nothing -> internalError "Cannot produce a buffer from UnknownCode"
                      else vmError IllegalOverflow
            _ -> underrun

        OpGasprice ->
          limitStack 1 . burn g_base $
            next >> push vm.tx.gasprice

        OpExtcodesize ->
          case stk of
            x':xs -> forceAddr x' "EXTCODESIZE" $ \x -> do
              let impl = accessAndBurn x $
                           fetchAccount x $ \c -> do
                             next
                             assign (#state % #stack) xs
                             case view bytecode c of
                               Just b -> pushSym (bufLength b)
                               Nothing -> pushSym $ CodeSize x
              case x of
                a@(LitAddr _) -> if a == cheatCode
                  then do
                    next
                    assign (#state % #stack) xs
                    pushSym (Lit 1)
                  else impl
                _ -> impl
            [] ->
              underrun

        OpExtcodecopy ->
          case stk of
            extAccount':memOffset':codeOffset:codeSize':xs ->
              forceConcrete2 (memOffset', codeSize') "EXTCODECOPY" $ \(memOffset, codeSize) -> do
                forceAddr extAccount' "EXTCODECOPY" $ \extAccount -> do
                  acc <- accessAccountForGas extAccount
                  let cost = if acc then g_warm_storage_read else g_cold_account_access
                  burn (cost + g_copy * ceilDiv (unsafeInto codeSize) 32) $
                    accessMemoryRange memOffset codeSize $
                      fetchAccount extAccount $ \c -> do
                        next
                        assign (#state % #stack) xs
                        case view bytecode c of
                          Just b -> copyBytesToMemory b codeSize' codeOffset memOffset'
                          Nothing -> do
                            pc <- use (#state % #pc)
                            partial $ UnexpectedSymbolicArg pc "Cannot copy from unknown code at" (wrap [extAccount])
            _ -> underrun

        OpReturndatasize ->
          limitStack 1 . burn g_base $
            next >> pushSym (bufLength vm.state.returndata)

        OpReturndatacopy ->
          case stk of
            xTo':xFrom:xSize':xs -> forceConcrete2 (xTo', xSize') "RETURNDATACOPY" $
              \(xTo, xSize) ->
                burn (g_verylow + g_copy * ceilDiv (unsafeInto xSize) 32) $
                  accessMemoryRange xTo xSize $ do
                    next
                    assign (#state % #stack) xs

                    let jump True = vmError ReturnDataOutOfBounds
                        jump False = copyBytesToMemory vm.state.returndata xSize' xFrom xTo'

                    case (xFrom, bufLength vm.state.returndata) of
                      (Lit f, Lit l) ->
                        jump $ l < f + xSize || f + xSize < f
                      _ -> do
                        let oob = Expr.lt (bufLength vm.state.returndata) (Expr.add xFrom xSize')
                            overflow = Expr.lt (Expr.add xFrom xSize') (xFrom)
                        branch (Expr.or oob overflow) jump
            _ -> underrun

        OpExtcodehash ->
          case stk of
            x':xs -> forceAddr x' "EXTCODEHASH" $ \x ->
              accessAndBurn x $ do
                next
                assign (#state % #stack) xs
                fetchAccount x $ \c ->
                   if accountEmpty c
                     then push (W256 0)
                     else case view bytecode c of
                            Just b -> pushSym $ keccak b
                            Nothing -> pushSym $ CodeHash x
            [] ->
              underrun

        OpBlockhash -> do
          -- We adopt the fake block hash scheme of the VMTests,
          -- so that blockhash(i) is the hash of i as decimal ASCII.
          stackOp1 g_blockhash $ \case
            Lit i -> if i + 256 < vm.block.number || i >= vm.block.number
                     then Lit 0
                     else (into i :: Integer) & show & Char8.pack & keccak' & Lit
            i -> BlockHash i

        OpCoinbase ->
          limitStack 1 . burn g_base $
            next >> pushAddr vm.block.coinbase

        OpTimestamp ->
          limitStack 1 . burn g_base $
            next >> pushSym vm.block.timestamp

        OpNumber ->
          limitStack 1 . burn g_base $
            next >> push vm.block.number

        OpPrevRandao -> do
          limitStack 1 . burn g_base $
            next >> push vm.block.prevRandao

        OpGaslimit ->
          limitStack 1 . burn g_base $
            next >> push (into vm.block.gaslimit)

        OpChainid ->
          limitStack 1 . burn g_base $
            next >> push vm.env.chainId

        OpSelfbalance ->
          limitStack 1 . burn g_low $
            next >> pushSym this.balance

        OpBaseFee ->
          limitStack 1 . burn g_base $
            next >> push vm.block.baseFee

        OpPop ->
          case stk of
            _:xs -> burn g_base (next >> assign (#state % #stack) xs)
            _    -> underrun

        OpMload ->
          case stk of
            x':xs -> forceConcrete x' "MLOAD" $ \x ->
              burn g_verylow $
                accessMemoryWord x $ do
                  next
                  buf <- readMemory (Lit x) (Lit 32)
                  let w = Expr.readWordFromBytes (Lit 0) buf
                  assign (#state % #stack) (w : xs)
            _ -> underrun

        OpMstore ->
          case stk of
            x':y:xs -> forceConcrete x' "MSTORE index" $ \x ->
              burn g_verylow $
                accessMemoryWord x $ do
                  next
                  gets (.state.memory) >>= \case
                    ConcreteMemory mem -> do
                      case y of
                        Lit w ->
                          writeMemory mem (unsafeInto x) (word256Bytes w)
                        _ -> do
                          -- copy out and move to symbolic memory
                          buf <- freezeMemory mem
                          assign (#state % #memory) (SymbolicMemory $ writeWord (Lit x) y buf)
                    SymbolicMemory mem ->
                      assign (#state % #memory) (SymbolicMemory $ writeWord (Lit x) y mem)
                  assign (#state % #stack) xs
            _ -> underrun

        OpMstore8 ->
          case stk of
            x':y:xs -> forceConcrete x' "MSTORE8" $ \x ->
              burn g_verylow $
                accessMemoryRange x 1 $ do
                  let yByte = indexWord (Lit 31) y
                  next
                  gets (.state.memory) >>= \case
                    ConcreteMemory mem -> do
                      case yByte of
                        LitByte byte ->
                          writeMemory mem (unsafeInto x) (BS.pack [byte])
                        _ -> do
                          -- copy out and move to symbolic memory
                          buf <- freezeMemory mem
                          assign (#state % #memory) (SymbolicMemory $ writeByte (Lit x) yByte buf)
                    SymbolicMemory mem ->
                      assign (#state % #memory) (SymbolicMemory $ writeByte (Lit x) yByte mem)

                  assign (#state % #stack) xs
            _ -> underrun

        OpSload ->
          case stk of
            x:xs -> do
              acc <- accessStorageForGas self x
              let cost = if acc then g_warm_storage_read else g_cold_sload
              burn cost $
                accessStorage self x $ \y -> do
                  next
                  assign (#state % #stack) (y:xs)
            _ -> underrun

        OpSstore ->
          notStatic $
          case stk of
            x:new:xs ->
              accessStorage self x $ \current -> do
                availableGas <- use (#state % #gas)

                if availableGas <= g_callstipend then
                  finishFrame (FrameErrored (OutOfGas availableGas g_callstipend))
                else do
                  let
                    original =
                      case Expr.simplify $ SLoad x this.origStorage of
                        Lit v -> v
                        _ -> 0
                    storage_cost =
                      case (maybeLitWord current, maybeLitWord new) of
                        (Just current', Just new') ->
                           if (current' == new') then g_sload
                           else if (current' == original) && (original == 0) then g_sset
                           else if (current' == original) then g_sreset
                           else g_sload

                        -- if any of the arguments are symbolic,
                        -- assume worst case scenario
                        _-> g_sset

                  acc <- accessStorageForGas self x
                  let cold_storage_cost = if acc then 0 else g_cold_sload
                  burn (storage_cost + cold_storage_cost) $ do
                    next
                    assign (#state % #stack) xs
                    modifying (#env % #contracts % ix self % #storage) (writeStorage x new)

                    case (maybeLitWord current, maybeLitWord new) of
                       (Just current', Just new') ->
                          unless (current' == new') $
                            if current' == original then
                              when (original /= 0 && new' == 0) $
                                refund (g_sreset + g_access_list_storage_key)
                            else do
                              when (original /= 0) $
                                if current' == 0
                                then unRefund (g_sreset + g_access_list_storage_key)
                                else when (new' == 0) $ refund (g_sreset + g_access_list_storage_key)
                              when (original == new') $
                                if original == 0
                                then refund (g_sset - g_sload)
                                else refund (g_sreset - g_sload)
                       -- if any of the arguments are symbolic,
                       -- don't change the refund counter
                       _ -> noop
            _ -> underrun

        OpJump ->
          case stk of
            x:xs ->
              burn g_mid $ forceConcrete x "JUMP: symbolic jumpdest" $ \x' ->
                case toInt x' of
                  Nothing -> vmError BadJumpDestination
                  Just i -> checkJump i xs
            _ -> underrun

        OpJumpi -> do
          case stk of
            (x:y:xs) -> forceConcrete x "JUMPI: symbolic jumpdest" $ \x' ->
                burn g_high $
                  let jump :: Bool -> EVM s ()
                      jump False = assign (#state % #stack) xs >> next
                      jump _    = case toInt x' of
                        Nothing -> vmError BadJumpDestination
                        Just i -> checkJump i xs
                  in branch y jump
            _ -> underrun

        OpPc ->
          limitStack 1 . burn g_base $
            next >> push (unsafeInto vm.state.pc)

        OpMsize ->
          limitStack 1 . burn g_base $
            next >> push (into vm.state.memorySize)

        OpGas ->
          limitStack 1 . burn g_base $
            next >> push (into (vm.state.gas - g_base))

        OpJumpdest -> burn g_jumpdest next

        OpExp ->
          -- NOTE: this can be done symbolically using unrolling like this:
          --       https://hackage.haskell.org/package/sbv-9.0/docs/src/Data.SBV.Core.Model.html#.%5E
          --       However, it requires symbolic gas, since the gas depends on the exponent
          case stk of
            base:exponent':xs -> forceConcrete exponent' "EXP: symbolic exponent" $ \exponent ->
              let cost = if exponent == 0
                         then g_exp
                         else g_exp + g_expbyte * unsafeInto (ceilDiv (1 + log2 exponent) 8)
              in burn cost $ do
                next
                (#state % #stack) .= Expr.exp base exponent' : xs
            _ -> underrun

        OpSignextend -> stackOp2 g_low Expr.sex

        OpCreate ->
          notStatic $
          case stk of
            xValue:xOffset':xSize':xs -> forceConcrete2 (xOffset', xSize') "CREATE" $
              \(xOffset, xSize) -> do
                accessMemoryRange xOffset xSize $ do
                  availableGas <- use (#state % #gas)
                  let
                    (cost, gas') = costOfCreate fees availableGas xSize False
                  newAddr <- createAddress self this.nonce
                  _ <- accessAccountForGas newAddr
                  burn cost $ do
                    initCode <- readMemory xOffset' xSize'
                    create self this xSize gas' xValue xs newAddr initCode
            _ -> underrun

        OpCall ->
          case stk of
            xGas':xTo':xValue:xInOffset':xInSize':xOutOffset':xOutSize':xs ->
              forceConcrete5 (xGas', xInOffset', xInSize', xOutOffset', xOutSize') "CALL" $
              \(xGas, xInOffset, xInSize, xOutOffset, xOutSize) ->
                branch (Expr.gt xValue (Lit 0)) $ \gt0 -> do
                  (if gt0 then notStatic else id) $
                    forceAddr xTo' "unable to determine a call target" $ \xTo ->
                      case tryFrom xGas of
                        Left _ -> vmError IllegalOverflow
                        Right gas ->
                          delegateCall this gas xTo xTo xValue xInOffset xInSize xOutOffset xOutSize xs $
                            \callee -> do
                              let from' = fromMaybe self vm.config.overrideCaller
                              zoom #state $ do
                                assign #callvalue xValue
                                assign #caller from'
                                assign #contract callee
                              assign (#config % #overrideCaller) Nothing
                              touchAccount from'
                              touchAccount callee
                              transfer from' callee xValue
            _ ->
              underrun

        OpCallcode ->
          case stk of
            xGas':xTo':xValue:xInOffset':xInSize':xOutOffset':xOutSize':xs ->
              forceConcrete5 (xGas', xInOffset', xInSize', xOutOffset', xOutSize') "CALLCODE" $
              \(xGas, xInOffset, xInSize, xOutOffset, xOutSize) ->
                forceAddr xTo' "unable to determine a call target" $ \xTo ->
                  case tryFrom xGas of
                    Left _ -> vmError IllegalOverflow
                    Right gas ->
                      delegateCall this gas xTo self xValue xInOffset xInSize xOutOffset xOutSize xs $ \_ -> do
                        zoom #state $ do
                          assign #callvalue xValue
                          assign #caller $ fromMaybe self vm.config.overrideCaller
                        assign (#config % #overrideCaller) Nothing
                        touchAccount self
            _ ->
              underrun

        OpReturn ->
          case stk of
            xOffset':xSize':_ -> forceConcrete2 (xOffset', xSize') "RETURN" $ \(xOffset, xSize) ->
              accessMemoryRange xOffset xSize $ do
                output <- readMemory xOffset' xSize'
                let
                  codesize = fromMaybe (internalError "processing opcode RETURN. Cannot return dynamically sized abstract data")
                               . maybeLitWord . bufLength $ output
                  maxsize = vm.block.maxCodeSize
                  creation = case vm.frames of
                    [] -> vm.tx.isCreate
                    frame:_ -> case frame.context of
                       CreationContext {} -> True
                       CallContext {} -> False
                if creation
                then
                  if codesize > maxsize
                  then
                    finishFrame (FrameErrored (MaxCodeSizeExceeded maxsize codesize))
                  else do
                    let frameReturned = burn (g_codedeposit * unsafeInto codesize) $
                                          finishFrame (FrameReturned output)
                        frameErrored = finishFrame $ FrameErrored InvalidFormat
                    case readByte (Lit 0) output of
                      LitByte 0xef -> frameErrored
                      LitByte _ -> frameReturned
                      y -> branch (Expr.eqByte y (LitByte 0xef)) $ \case
                          True -> frameErrored
                          False -> frameReturned
                else
                   finishFrame (FrameReturned output)
            _ -> underrun

        OpDelegatecall ->
          case stk of
            xGas':xTo:xInOffset':xInSize':xOutOffset':xOutSize':xs ->
              forceConcrete5 (xGas', xInOffset', xInSize', xOutOffset', xOutSize') "DELEGATECALL" $
              \(xGas, xInOffset, xInSize, xOutOffset, xOutSize) ->
                case wordToAddr xTo of
                  Nothing -> do
                    loc <- codeloc
                    let msg = "Unable to determine a call target"
                    partial $ UnexpectedSymbolicArg (snd loc) msg [SomeExpr xTo]
                  Just xTo' ->
                    case tryFrom xGas of
                      Left _ -> vmError IllegalOverflow
                      Right gas ->
                        delegateCall this gas xTo' self (Lit 0) xInOffset xInSize xOutOffset xOutSize xs $
                          \_ -> touchAccount self
            _ -> underrun

        OpCreate2 -> notStatic $
          case stk of
            xValue:xOffset':xSize':xSalt':xs ->
              forceConcrete3 (xOffset', xSize', xSalt') "CREATE2" $
              \(xOffset, xSize, xSalt) ->
                accessMemoryRange xOffset xSize $ do
                  availableGas <- use (#state % #gas)
                  buf <- readMemory xOffset' xSize'
                  forceConcreteBuf buf "CREATE2" $
                    \initCode -> do
                      let
                        (cost, gas') = costOfCreate fees availableGas xSize True
                      newAddr <- create2Address self xSalt initCode
                      _ <- accessAccountForGas newAddr
                      burn cost $
                        create self this xSize gas' xValue xs newAddr (ConcreteBuf initCode)
            _ -> underrun

        OpStaticcall ->
          case stk of
            xGas':xTo:xInOffset':xInSize':xOutOffset':xOutSize':xs ->
              forceConcrete5 (xGas', xInOffset', xInSize', xOutOffset', xOutSize') "STATICCALL" $
              \(xGas, xInOffset, xInSize, xOutOffset, xOutSize) -> do
                case wordToAddr xTo of
                  Nothing -> do
                    loc <- codeloc
                    let msg = "Unable to determine a call target"
                    partial $ UnexpectedSymbolicArg (snd loc) msg [SomeExpr xTo]
                  Just xTo' ->
                    case tryFrom xGas of
                      Left _ -> vmError IllegalOverflow
                      Right gas ->
                        delegateCall this gas xTo' xTo' (Lit 0) xInOffset xInSize xOutOffset xOutSize xs $
                          \callee -> do
                            zoom #state $ do
                              assign #callvalue (Lit 0)
                              assign #caller $ fromMaybe self (vm.config.overrideCaller)
                              assign #contract callee
                              assign #static True
                            assign (#config % #overrideCaller) Nothing
                            touchAccount self
                            touchAccount callee
            _ ->
              underrun

        OpSelfdestruct ->
          notStatic $
          case stk of
            [] -> underrun
            (xTo':_) -> forceAddr xTo' "SELFDESTRUCT" $ \case
              xTo@(LitAddr _) -> do
                acc <- accessAccountForGas xTo
                let cost = if acc then 0 else g_cold_account_access
                    funds = this.balance
                    recipientExists = accountExists xTo vm
                branch (Expr.iszero $ Expr.eq funds (Lit 0)) $ \hasFunds -> do
                  let c_new = if (not recipientExists) && hasFunds
                              then g_selfdestruct_newaccount
                              else 0
                  burn (g_selfdestruct + c_new + cost) $ do
                    selfdestruct self
                    touchAccount xTo

                    if hasFunds
                    then fetchAccount xTo $ \_ -> do
                           #env % #contracts % ix xTo % #balance %= (Expr.add funds)
                           assign (#env % #contracts % ix self % #balance) (Lit 0)
                           doStop
                    else do
                      doStop
              a -> do
                pc <- use (#state % #pc)
                partial $ UnexpectedSymbolicArg pc "trying to self destruct to a symbolic address" (wrap [a])

        OpRevert ->
          case stk of
            xOffset':xSize':_ -> forceConcrete2 (xOffset', xSize') "REVERT" $ \(xOffset, xSize) ->
              accessMemoryRange xOffset xSize $ do
                output <- readMemory xOffset' xSize'
                finishFrame (FrameReverted output)
            _ -> underrun

        OpUnknown xxx ->
          vmError $ UnrecognizedOpcode xxx

transfer :: Expr EAddr -> Expr EAddr -> Expr EWord -> EVM s ()
transfer _ _ (Lit 0) = pure ()
transfer src dst val = do
  sb <- preuse $ #env % #contracts % ix src % #balance
  db <- preuse $ #env % #contracts % ix dst % #balance
  baseState <- use (#config % #baseState)
  let mkc = case baseState of
              AbstractBase -> unknownContract
              EmptyBase -> const emptyContract
  case (sb, db) of
    -- both sender and recipient in state
    (Just srcBal, Just _) ->
      branch (Expr.gt val srcBal) $ \case
        True -> vmError $ BalanceTooLow val srcBal
        False -> do
          (#env % #contracts % ix src % #balance) %= (`Expr.sub` val)
          (#env % #contracts % ix dst % #balance) %= (`Expr.add` val)
    -- sender not in state
    (Nothing, Just _) -> do
      case src of
        LitAddr _ -> do
          (#env % #contracts) %= (Map.insert src (mkc src))
          transfer src dst val
        SymAddr _ -> do
          pc <- use (#state % #pc)
          partial $ UnexpectedSymbolicArg pc "Attempting to transfer eth from a symbolic address that is not present in the state" (wrap [src])
        GVar _ -> internalError "Unexpected GVar"
    -- recipient not in state
    (_ , Nothing) -> do
      case dst of
        LitAddr _ -> do
          (#env % #contracts) %= (Map.insert dst (mkc dst))
          transfer src dst val
        SymAddr _ -> do
          pc <- use (#state % #pc)
          partial $ UnexpectedSymbolicArg pc "Attempting to transfer eth to a symbolic address that is not present in the state" (wrap [dst])
        GVar _ -> internalError "Unexpected GVar"

-- | Checks a *CALL for failure; OOG, too many callframes, memory access etc.
callChecks
  :: (?op :: Word8)
  => Contract -> Word64 -> Expr EAddr -> Expr EAddr -> Expr EWord -> W256 -> W256 -> W256 -> W256 -> [Expr EWord]
   -- continuation with gas available for call
  -> (Word64 -> EVM s ())
  -> EVM s ()
callChecks this xGas xContext xTo xValue xInOffset xInSize xOutOffset xOutSize xs continue = do
  vm <- get
  let fees = vm.block.schedule
  accessMemoryRange xInOffset xInSize $
    accessMemoryRange xOutOffset xOutSize $ do
      availableGas <- use (#state % #gas)
      let recipientExists = accountExists xContext vm
      (cost, gas') <- costOfCall fees recipientExists xValue availableGas xGas xTo
      burn (cost - gas') $
        branch (Expr.gt xValue this.balance) $ \case
          True -> do
            assign (#state % #stack) (Lit 0 : xs)
            assign (#state % #returndata) mempty
            pushTrace $ ErrorTrace (BalanceTooLow xValue this.balance)
            next
          False ->
            if length vm.frames >= 1024
            then do
              assign (#state % #stack) (Lit 0 : xs)
              assign (#state % #returndata) mempty
              pushTrace $ ErrorTrace CallDepthLimitReached
              next
            else continue gas'

precompiledContract
  :: (?op :: Word8)
  => Contract
  -> Word64
  -> Addr
  -> Addr
  -> Expr EWord
  -> W256 -> W256 -> W256 -> W256
  -> [Expr EWord]
  -> EVM s ()
precompiledContract this xGas precompileAddr recipient xValue inOffset inSize outOffset outSize xs
  = callChecks this xGas (LitAddr recipient) (LitAddr precompileAddr) xValue inOffset inSize outOffset outSize xs $ \gas' ->
    do
      executePrecompile precompileAddr gas' inOffset inSize outOffset outSize xs
      self <- use (#state % #contract)
      stk <- use (#state % #stack)
      pc' <- use (#state % #pc)
      result' <- use #result
      case result' of
        Nothing -> case stk of
          x:_ -> case maybeLitWord x of
            Just 0 ->
              pure ()
            Just 1 ->
              fetchAccount (LitAddr recipient) $ \_ -> do
                touchAccount self
                touchAccount (LitAddr recipient)
                transfer self (LitAddr recipient) xValue
            _ -> partial $
                   UnexpectedSymbolicArg pc' "unexpected return value from precompile" (wrap [x])
          _ -> underrun
        _ -> pure ()

executePrecompile
  :: (?op :: Word8)
  => Addr
  -> Word64 -> W256 -> W256 -> W256 -> W256 -> [Expr EWord]
  -> EVM s ()
executePrecompile preCompileAddr gasCap inOffset inSize outOffset outSize xs  = do
  vm <- get
  input <- readMemory (Lit inOffset) (Lit inSize)
  let fees = vm.block.schedule
      cost = costOfPrecompile fees preCompileAddr input
      notImplemented = internalError $ "precompile at address " <> show preCompileAddr <> " not yet implemented"
      precompileFail = burn (gasCap - cost) $ do
                         assign (#state % #stack) (Lit 0 : xs)
                         pushTrace $ ErrorTrace PrecompileFailure
                         next
  if cost > gasCap then
    burn gasCap $ do
      assign (#state % #stack) (Lit 0 : xs)
      next
  else burn cost $
    case preCompileAddr of
      -- ECRECOVER
      0x1 ->
        -- TODO: support symbolic variant
        forceConcreteBuf input "ECRECOVER" $ \input' -> do
          case EVM.Precompiled.execute 0x1 (truncpadlit 128 input') 32 of
            Nothing -> do
              -- return no output for invalid signature
              assign (#state % #stack) (Lit 1 : xs)
              assign (#state % #returndata) mempty
              next
            Just output -> do
              assign (#state % #stack) (Lit 1 : xs)
              assign (#state % #returndata) (ConcreteBuf output)
              copyBytesToMemory (ConcreteBuf output) (Lit outSize) (Lit 0) (Lit outOffset)
              next

      -- SHA2-256
      0x2 ->
        forceConcreteBuf input "SHA2-256" $ \input' -> do
          let
            hash = sha256Buf input'
            sha256Buf x = ConcreteBuf $ BA.convert (Crypto.hash x :: Digest SHA256)
          assign (#state % #stack) (Lit 1 : xs)
          assign (#state % #returndata) hash
          copyBytesToMemory hash (Lit outSize) (Lit 0) (Lit outOffset)
          next

      -- RIPEMD-160
      0x3 ->
        -- TODO: support symbolic variant
        forceConcreteBuf input "RIPEMD160" $ \input' -> do
          let
            padding = BS.pack $ replicate 12 0
            hash' = BA.convert (Crypto.hash input' :: Digest RIPEMD160)
            hash  = ConcreteBuf $ padding <> hash'
          assign (#state % #stack) (Lit 1 : xs)
          assign (#state % #returndata) hash
          copyBytesToMemory hash (Lit outSize) (Lit 0) (Lit outOffset)
          next

      -- IDENTITY
      0x4 -> do
          assign (#state % #stack) (Lit 1 : xs)
          assign (#state % #returndata) input
          copyCallBytesToMemory input (Lit outSize) (Lit outOffset)
          next

      -- MODEXP
      0x5 ->
        -- TODO: support symbolic variant
        forceConcreteBuf input "MODEXP" $ \input' -> do
          let
            (lenb, lene, lenm) = parseModexpLength input'

            output = ConcreteBuf $
              if isZero (96 + lenb + lene) lenm input'
              then truncpadlit (unsafeInto lenm) (asBE (0 :: Int))
              else
                let
                  b = asInteger $ lazySlice 96 lenb input'
                  e = asInteger $ lazySlice (96 + lenb) lene input'
                  m = asInteger $ lazySlice (96 + lenb + lene) lenm input'
                in
                  padLeft (unsafeInto lenm) (asBE (expFast b e m))
          assign (#state % #stack) (Lit 1 : xs)
          assign (#state % #returndata) output
          copyBytesToMemory output (Lit outSize) (Lit 0) (Lit outOffset)
          next

      -- ECADD
      0x6 ->
        -- TODO: support symbolic variant
        forceConcreteBuf input "ECADD" $ \input' ->
          case EVM.Precompiled.execute 0x6 (truncpadlit 128 input') 64 of
            Nothing -> precompileFail
            Just output -> do
              let truncpaddedOutput = ConcreteBuf $ truncpadlit 64 output
              assign (#state % #stack) (Lit 1 : xs)
              assign (#state % #returndata) truncpaddedOutput
              copyBytesToMemory truncpaddedOutput (Lit outSize) (Lit 0) (Lit outOffset)
              next

      -- ECMUL
      0x7 ->
        -- TODO: support symbolic variant
        forceConcreteBuf input "ECMUL" $ \input' ->
          case EVM.Precompiled.execute 0x7 (truncpadlit 96 input') 64 of
          Nothing -> precompileFail
          Just output -> do
            let truncpaddedOutput = ConcreteBuf $ truncpadlit 64 output
            assign (#state % #stack) (Lit 1 : xs)
            assign (#state % #returndata) truncpaddedOutput
            copyBytesToMemory truncpaddedOutput (Lit outSize) (Lit 0) (Lit outOffset)
            next

      -- ECPAIRING
      0x8 ->
        -- TODO: support symbolic variant
        forceConcreteBuf input "ECPAIR" $ \input' ->
          case EVM.Precompiled.execute 0x8 input' 32 of
          Nothing -> precompileFail
          Just output -> do
            let truncpaddedOutput = ConcreteBuf $ truncpadlit 32 output
            assign (#state % #stack) (Lit 1 : xs)
            assign (#state % #returndata) truncpaddedOutput
            copyBytesToMemory truncpaddedOutput (Lit outSize) (Lit 0) (Lit outOffset)
            next

      -- BLAKE2
      0x9 ->
        -- TODO: support symbolic variant
        forceConcreteBuf input "BLAKE2" $ \input' -> do
          case (BS.length input', 1 >= BS.last input') of
            (213, True) -> case EVM.Precompiled.execute 0x9 input' 64 of
              Just output -> do
                let truncpaddedOutput = ConcreteBuf $ truncpadlit 64 output
                assign (#state % #stack) (Lit 1 : xs)
                assign (#state % #returndata) truncpaddedOutput
                copyBytesToMemory truncpaddedOutput (Lit outSize) (Lit 0) (Lit outOffset)
                next
              Nothing -> precompileFail
            _ -> precompileFail

      _ -> notImplemented

truncpadlit :: Int -> ByteString -> ByteString
truncpadlit n xs = if m > n then BS.take n xs
                   else BS.append xs (BS.replicate (n - m) 0)
  where m = BS.length xs

lazySlice :: W256 -> W256 -> ByteString -> LS.ByteString
lazySlice offset size bs =
  let bs' = LS.take (unsafeInto size) (LS.drop (unsafeInto offset) (fromStrict bs))
  in bs' <> LS.replicate (unsafeInto size - LS.length bs') 0

parseModexpLength :: ByteString -> (W256, W256, W256)
parseModexpLength input =
  let lenb = word $ LS.toStrict $ lazySlice  0 32 input
      lene = word $ LS.toStrict $ lazySlice 32 64 input
      lenm = word $ LS.toStrict $ lazySlice 64 96 input
  in (lenb, lene, lenm)

--- checks if a range of ByteString bs starting at offset and length size is all zeros.
isZero :: W256 -> W256 -> ByteString -> Bool
isZero offset size bs =
  LS.all (== 0) $
    LS.take (unsafeInto size) $
      LS.drop (unsafeInto offset) $
        fromStrict bs

asInteger :: LS.ByteString -> Integer
asInteger xs = if xs == mempty then 0
  else 256 * asInteger (LS.init xs)
      + into (LS.last xs)

-- * Opcode helper actions

noop :: Monad m => m ()
noop = pure ()

pushTo :: MonadState s m => Lens s s [a] [a] -> a -> m ()
pushTo f x = f %= (x :)

pushToSequence :: MonadState s m => Setter s s (Seq a) (Seq a) -> a -> m ()
pushToSequence f x = f %= (Seq.|> x)

getCodeLocation :: VM s -> CodeLocation
getCodeLocation vm = (vm.state.contract, vm.state.pc)

query :: Query s -> EVM s ()
query = assign #result . Just . HandleEffect . Query

choose :: Choose s -> EVM s ()
choose = assign #result . Just . HandleEffect . Choose

branch :: forall s. Expr EWord -> (Bool -> EVM s ()) -> EVM s ()
branch cond continue = do
  loc <- codeloc
  pathconds <- use #constraints
  query $ PleaseAskSMT cond pathconds (choosePath loc)
  where
    condSimp = Expr.simplify cond
    choosePath :: CodeLocation -> BranchCondition -> EVM s ()
    choosePath loc (Case v) = do
      assign #result Nothing
      pushTo #constraints $ if v then Expr.evalProp (condSimp ./= Lit 0) else Expr.evalProp (condSimp .== Lit 0)
      (iteration, _) <- use (#iterations % at loc % non (0,[]))
      stack <- use (#state % #stack)
      assign (#cache % #path % at (loc, iteration)) (Just v)
      assign (#iterations % at loc) (Just (iteration + 1, stack))
      continue v
    -- Both paths are possible; we ask for more input
    choosePath loc Unknown =
      choose . PleaseChoosePath condSimp $ choosePath loc . Case

-- | Construct RPC Query and halt execution until resolved
fetchAccount :: Expr EAddr -> (Contract -> EVM s ()) -> EVM s ()
fetchAccount addr continue =
  use (#env % #contracts % at addr) >>= \case
    Just c -> continue c
    Nothing -> case addr of
      SymAddr _ -> do
        pc <- use (#state % #pc)
        partial $ UnexpectedSymbolicArg pc "trying to access a symbolic address that isn't already present in storage" (wrap [addr])
      LitAddr a -> do
        use (#cache % #fetched % at a) >>= \case
          Just c -> do
            assign (#env % #contracts % at addr) (Just c)
            continue c
          Nothing -> do
            base <- use (#config % #baseState)
            assign (#result) . Just . HandleEffect . Query $
              PleaseFetchContract a base
                (\c -> do assign (#cache % #fetched % at a) (Just c)
                          assign (#env % #contracts % at addr) (Just c)
                          assign #result Nothing
                          continue c)
      GVar _ -> internalError "Unexpected GVar"

accessStorage
  :: Expr EAddr
  -> Expr EWord
  -> (Expr EWord -> EVM s ())
  -> EVM s ()
accessStorage addr slot continue = do
  use (#env % #contracts % at addr) >>= \case
    Just c ->
      case readStorage slot c.storage of
        Just x ->
          continue x
        Nothing ->
          if c.external then
            forceConcreteAddr addr "cannot read storage from symbolic addresses via rpc" $ \addr' ->
              forceConcrete slot "cannot read symbolic slots via RPC" $ \slot' -> do
                -- check if the slot is cached
                contract <- preuse (#cache % #fetched % ix addr')
                case contract of
                  Nothing -> internalError "contract marked external not found in cache"
                  Just fetched -> case readStorage (Lit slot') fetched.storage of
                              Nothing -> mkQuery addr' slot'
                              Just val -> continue val
          else do
            modifying (#env % #contracts % ix addr % #storage) (writeStorage slot (Lit 0))
            continue $ Lit 0
    Nothing ->
      fetchAccount addr $ \_ ->
        accessStorage addr slot continue
  where
      mkQuery a s = query $
        PleaseFetchSlot a s
          (\x -> do
              modifying (#cache % #fetched % ix a % #storage) (writeStorage (Lit s) (Lit x))
              modifying (#env % #contracts % ix (LitAddr a) % #storage) (writeStorage (Lit s) (Lit x))
              assign #result Nothing
              continue (Lit x))

accountExists :: Expr EAddr -> VM s -> Bool
accountExists addr vm =
  case Map.lookup addr vm.env.contracts of
    Just c -> not (accountEmpty c)
    Nothing -> False

-- EIP 161
accountEmpty :: Contract -> Bool
accountEmpty c =
  case c.code of
    RuntimeCode (ConcreteRuntimeCode "") -> True
    RuntimeCode (SymbolicRuntimeCode b) -> null b
    _ -> False
  && c.nonce == (Just 0)
  -- TODO: handle symbolic balance...
  && c.balance == Lit 0

-- * How to finalize a transaction
finalize :: EVM s ()
finalize = do
  let
    revertContracts  = use (#tx % #txReversion) >>= assign (#env % #contracts)
    revertSubstate   = assign (#tx % #substate) (SubState mempty mempty mempty mempty mempty)

  use #result >>= \case
    Just (VMFailure (Revert _)) -> do
      revertContracts
      revertSubstate
    Just (VMFailure _) -> do
      -- burn remaining gas
      assign (#state % #gas) 0
      revertContracts
      revertSubstate
    Just (VMSuccess output) -> do
      -- deposit the code from a creation tx
      pc' <- use (#state % #pc)
      creation <- use (#tx % #isCreate)
      createe  <- use (#state % #contract)
      createeExists <- (Map.member createe) <$> use (#env % #contracts)
      let onContractCode contractCode =
            when (creation && createeExists) $ replaceCode createe contractCode
      case output of
        ConcreteBuf bs ->
          onContractCode $ RuntimeCode (ConcreteRuntimeCode bs)
        _ ->
          case Expr.toList output of
            Nothing ->
              partial $
                UnexpectedSymbolicArg pc' "runtime code cannot have an abstract lentgh" (wrap [output])
            Just ops ->
              onContractCode $ RuntimeCode (SymbolicRuntimeCode ops)
    _ ->
      internalError "Finalising an unfinished tx."

  -- compute and pay the refund to the caller and the
  -- corresponding payment to the miner
  block        <- use #block
  tx           <- use #tx
  gasRemaining <- use (#state % #gas)

  let
    sumRefunds   = sum (snd <$> tx.substate.refunds)
    gasUsed      = tx.gaslimit - gasRemaining
    cappedRefund = min (quot gasUsed 5) sumRefunds
    originPay    = (into $ gasRemaining + cappedRefund) * tx.gasprice
    minerPay     = tx.priorityFee * (into gasUsed)

  modifying (#env % #contracts)
     (Map.adjust (over #balance (Expr.add (Lit originPay))) tx.origin)
  modifying (#env % #contracts)
     (Map.adjust (over #balance (Expr.add (Lit minerPay))) block.coinbase)
  touchAccount block.coinbase

  -- perform state trie clearing (EIP 161), of selfdestructs
  -- and touched accounts. addresses are cleared if they have
  --    a) selfdestructed, or
  --    b) been touched and
  --    c) are empty.
  -- (see Yellow Paper "Accrued Substate")
  --
  -- remove any destructed addresses
  destroyedAddresses <- use (#tx % #substate % #selfdestructs)
  modifying (#env % #contracts)
    (Map.filterWithKey (\k _ -> (k `notElem` destroyedAddresses)))
  -- then, clear any remaining empty and touched addresses
  touchedAddresses <- use (#tx % #substate % #touchedAccounts)
  modifying (#env % #contracts)
    (Map.filterWithKey
      (\k a -> not ((k `elem` touchedAddresses) && accountEmpty a)))

-- | Loads the selected contract as the current contract to execute
loadContract :: Expr EAddr -> State (VM s) ()
loadContract target =
  preuse (#env % #contracts % ix target % #code) >>=
    \case
      Nothing ->
        internalError "Call target doesn't exist"
      Just targetCode -> do
        assign (#state % #contract) target
        assign (#state % #code)     targetCode
        assign (#state % #codeContract) target

limitStack :: Int -> EVM s () -> EVM s ()
limitStack n continue = do
  stk <- use (#state % #stack)
  if length stk + n > 1024
    then vmError StackLimitExceeded
    else continue

notStatic :: EVM s () -> EVM s ()
notStatic continue = do
  bad <- use (#state % #static)
  if bad
    then vmError StateChangeWhileStatic
    else continue

-- | Burn gas, failing if insufficient gas is available
burn :: Word64 -> EVM s () -> EVM s ()
burn n continue = do
  available <- use (#state % #gas)
  if n <= available
    then do
      #state % #gas %= (subtract n)
      #burned %= (+ n)
      continue
    else
      vmError (OutOfGas available n)

forceAddr :: Expr EWord -> String -> (Expr EAddr -> EVM s ()) -> EVM s ()
forceAddr n msg continue = case wordToAddr n of
  Nothing -> do
    vm <- get
    partial $ UnexpectedSymbolicArg vm.state.pc msg (wrap [n])
  Just c -> continue c

forceConcrete :: Expr EWord -> String -> (W256 -> EVM s ()) -> EVM s ()
forceConcrete n msg continue = case maybeLitWord n of
  Nothing -> do
    vm <- get
    partial $ UnexpectedSymbolicArg vm.state.pc msg (wrap [n])
  Just c -> continue c

forceConcreteAddr :: Expr EAddr -> String -> (Addr -> EVM s ()) -> EVM s ()
forceConcreteAddr n msg continue = case maybeLitAddr n of
  Nothing -> do
    vm <- get
    partial $ UnexpectedSymbolicArg vm.state.pc msg (wrap [n])
  Just c -> continue c

forceConcreteAddr2 :: (Expr EAddr, Expr EAddr) -> String -> ((Addr, Addr) -> EVM s ()) -> EVM s ()
forceConcreteAddr2 (n,m) msg continue = case (maybeLitAddr n, maybeLitAddr m) of
  (Just c, Just d) -> continue (c,d)
  _ -> do
    vm <- get
    partial $ UnexpectedSymbolicArg vm.state.pc msg (wrap [n, m])

forceConcrete2 :: (Expr EWord, Expr EWord) -> String -> ((W256, W256) -> EVM s ()) -> EVM s ()
forceConcrete2 (n,m) msg continue = case (maybeLitWord n, maybeLitWord m) of
  (Just c, Just d) -> continue (c, d)
  _ -> do
    vm <- get
    partial $ UnexpectedSymbolicArg vm.state.pc msg (wrap [n, m])

forceConcrete3 :: (Expr EWord, Expr EWord, Expr EWord) -> String -> ((W256, W256, W256) -> EVM s ()) -> EVM s ()
forceConcrete3 (k,n,m) msg continue = case (maybeLitWord k, maybeLitWord n, maybeLitWord m) of
  (Just c, Just d, Just f) -> continue (c, d, f)
  _ -> do
    vm <- get
    partial $ UnexpectedSymbolicArg vm.state.pc msg (wrap [k, n, m])

forceConcrete4 :: (Expr EWord, Expr EWord, Expr EWord, Expr EWord) -> String -> ((W256, W256, W256, W256) -> EVM s ()) -> EVM s ()
forceConcrete4 (k,l,n,m) msg continue = case (maybeLitWord k, maybeLitWord l, maybeLitWord n, maybeLitWord m) of
  (Just b, Just c, Just d, Just f) -> continue (b, c, d, f)
  _ -> do
    vm <- get
    partial $ UnexpectedSymbolicArg vm.state.pc msg (wrap [k, l, n, m])

forceConcrete5 :: (Expr EWord, Expr EWord, Expr EWord, Expr EWord, Expr EWord) -> String -> ((W256, W256, W256, W256, W256) -> EVM s ()) -> EVM s ()
forceConcrete5 (k,l,m,n,o) msg continue = case (maybeLitWord k, maybeLitWord l, maybeLitWord m, maybeLitWord n, maybeLitWord o) of
  (Just a, Just b, Just c, Just d, Just e) -> continue (a, b, c, d, e)
  _ -> do
    vm <- get
    partial $ UnexpectedSymbolicArg vm.state.pc msg (wrap [k, l, m, n, o])

forceConcrete6 :: (Expr EWord, Expr EWord, Expr EWord, Expr EWord, Expr EWord, Expr EWord) -> String -> ((W256, W256, W256, W256, W256, W256) -> EVM s ()) -> EVM s ()
forceConcrete6 (k,l,m,n,o,p) msg continue = case (maybeLitWord k, maybeLitWord l, maybeLitWord m, maybeLitWord n, maybeLitWord o, maybeLitWord p) of
  (Just a, Just b, Just c, Just d, Just e, Just f) -> continue (a, b, c, d, e, f)
  _ -> do
    vm <- get
    partial $ UnexpectedSymbolicArg vm.state.pc msg (wrap [k, l, m, n, o, p])

forceConcreteBuf :: Expr Buf -> String -> (ByteString -> EVM s ()) -> EVM s ()
forceConcreteBuf (ConcreteBuf b) _ continue = continue b
forceConcreteBuf b msg _ = do
    vm <- get
    partial $ UnexpectedSymbolicArg vm.state.pc msg (wrap [b])

-- * Substate manipulation
refund :: Word64 -> EVM s ()
refund n = do
  self <- use (#state % #contract)
  pushTo (#tx % #substate % #refunds) (self, n)

unRefund :: Word64 -> EVM s ()
unRefund n = do
  self <- use (#state % #contract)
  refs <- use (#tx % #substate % #refunds)
  assign (#tx % #substate % #refunds)
    (filter (\(a,b) -> not (a == self && b == n)) refs)

touchAccount :: Expr EAddr -> EVM s ()
touchAccount = pushTo ((#tx % #substate) % #touchedAccounts)

selfdestruct :: Expr EAddr -> EVM s ()
selfdestruct = pushTo ((#tx % #substate) % #selfdestructs)

accessAndBurn :: Expr EAddr -> EVM s () -> EVM s ()
accessAndBurn x cont = do
  FeeSchedule {..} <- use (#block % #schedule)
  acc <- accessAccountForGas x
  let cost = if acc then g_warm_storage_read else g_cold_account_access
  burn cost cont

-- | returns a wrapped boolean- if true, this address has been touched before in the txn (warm gas cost as in EIP 2929)
-- otherwise cold
accessAccountForGas :: Expr EAddr -> EVM s Bool
accessAccountForGas addr = do
  accessedAddrs <- use (#tx % #substate % #accessedAddresses)
  let accessed = member addr accessedAddrs
  assign (#tx % #substate % #accessedAddresses) (insert addr accessedAddrs)
  pure accessed

-- | returns a wrapped boolean- if true, this slot has been touched before in the txn (warm gas cost as in EIP 2929)
-- otherwise cold
accessStorageForGas :: Expr EAddr -> Expr EWord -> EVM s Bool
accessStorageForGas addr key = do
  accessedStrkeys <- use (#tx % #substate % #accessedStorageKeys)
  case maybeLitWord key of
    Just litword -> do
      let accessed = member (addr, litword) accessedStrkeys
      assign (#tx % #substate % #accessedStorageKeys) (insert (addr, litword) accessedStrkeys)
      pure accessed
    _ -> return False

-- * Cheat codes

-- The cheat code is 7109709ecfa91a80626ff3989d68f67f5b1dd12d.
-- Call this address using one of the cheatActions below to do
-- special things, e.g. changing the block timestamp. Beware that
-- these are necessarily hevm specific.
cheatCode :: Expr EAddr
cheatCode = LitAddr $ unsafeInto (keccak' "hevm cheat code")

cheat
  :: (?op :: Word8)
  => (W256, W256) -> (W256, W256)
  -> EVM s ()
cheat (inOffset, inSize) (outOffset, outSize) = do
  vm <- get
  input <- readMemory (Lit $ inOffset + 4) (Lit $ inSize - 4)
  abi <- readBytes 4 (Lit 0) <$> readMemory (Lit inOffset) (Lit 4)
  pushTrace $ FrameTrace (CallContext cheatCode cheatCode inOffset inSize (Lit 0) (maybeLitWord abi) input vm.env.contracts vm.tx.substate)
  case maybeLitWord abi of
    Nothing -> partial $ UnexpectedSymbolicArg vm.state.pc "symbolic cheatcode selector" (wrap [abi])
    Just (unsafeInto -> abi') ->
      case Map.lookup abi' cheatActions of
        Nothing ->
          vmError (BadCheatCode abi')
        Just action -> do
            action (Lit outOffset) (Lit outSize) input
            popTrace
            next
            push 1

type CheatAction s = Expr EWord -> Expr EWord -> Expr Buf -> EVM s ()

cheatActions :: Map FunctionSelector (CheatAction s)
cheatActions =
  Map.fromList
    [ action "ffi(string[])" $
        \sig outOffset outSize input -> do
          vm <- get
          if vm.config.allowFFI then
            case decodeBuf [AbiArrayDynamicType AbiStringType] input of
              CAbi valsArr -> case valsArr of
                [AbiArrayDynamic AbiStringType strsV] ->
                  let
                    cmd = fmap
                            (\case
                              (AbiString a) -> unpack $ decodeUtf8 a
                              _ -> "")
                            (V.toList strsV)
                    cont bs = do
                      let encoded = ConcreteBuf bs
                      assign (#state % #returndata) encoded
                      copyBytesToMemory encoded outSize (Lit 0) outOffset
                      assign #result Nothing
                  in query (PleaseDoFFI cmd cont)
                _ -> vmError (BadCheatCode sig)
              _ -> vmError (BadCheatCode sig)
          else
            let msg = "ffi disabled: run again with --ffi if you want to allow tests to call external scripts"
            in partial $ UnexpectedSymbolicArg vm.state.pc msg [],

      action "warp(uint256)" $
        \sig _ _ input -> case decodeStaticArgs 0 1 input of
          [x]  -> assign (#block % #timestamp) x
          _ -> vmError (BadCheatCode sig),

      action "deal(address,uint256)" $
        \sig _ _ input -> case decodeStaticArgs 0 2 input of
          [a, amt] ->
            forceAddr a "vm.deal: cannot decode target into an address" $ \usr ->
              fetchAccount usr $ \_ -> do
                assign (#env % #contracts % ix usr % #balance) amt
          _ -> vmError (BadCheatCode sig),

      action "assume(bool)" $
        \sig _ _ input -> case decodeStaticArgs 0 1 input of
          [c] -> modifying #constraints ((:) (PEq c (Lit 1)))
          _ -> vmError (BadCheatCode sig),

      action "roll(uint256)" $
        \sig _ _ input -> case decodeStaticArgs 0 1 input of
          [x] -> forceConcrete x "cannot roll to a symbolic block number" (assign (#block % #number))
          _ -> vmError (BadCheatCode sig),

      action "store(address,bytes32,bytes32)" $
        \sig _ _ input -> case decodeStaticArgs 0 3 input of
          [a, slot, new] -> case wordToAddr a of
            Just a'@(LitAddr _) -> fetchAccount a' $ \_ ->
              modifying (#env % #contracts % ix a' % #storage) (writeStorage slot new)
            _ -> vmError (BadCheatCode sig)
          _ -> vmError (BadCheatCode sig),

      action "load(address,bytes32)" $
        \sig outOffset _ input -> case decodeStaticArgs 0 2 input of
          [a, slot] -> case wordToAddr a of
            Just a'@(LitAddr _) -> fetchAccount a' $ \_ ->
              accessStorage a' slot $ \res -> do
                assign (#state % #returndata % word256At (Lit 0)) res
                let buf = writeWord (Lit 0) res (ConcreteBuf "")
                copyBytesToMemory buf (Lit 32) (Lit 0) outOffset
            _ -> vmError (BadCheatCode sig)
          _ -> vmError (BadCheatCode sig),

      action "sign(uint256,bytes32)" $
        \sig outOffset _ input -> case decodeStaticArgs 0 2 input of
          [sk, hash] ->
            forceConcrete2 (sk, hash) "cannot sign symbolic data" $ \(sk', hash') -> do
              let (v,r,s) = EVM.Sign.sign hash' (toInteger sk')
                  encoded = encodeAbiValue $
                    AbiTuple (V.fromList
                      [ AbiUInt 8 $ into v
                      , AbiBytes 32 (word256Bytes r)
                      , AbiBytes 32 (word256Bytes s)
                      ])
              assign (#state % #returndata) (ConcreteBuf encoded)
              copyBytesToMemory (ConcreteBuf encoded) (Lit . unsafeInto . BS.length $ encoded) (Lit 0) outOffset
          _ -> vmError (BadCheatCode sig),

      action "addr(uint256)" $
        \sig outOffset _ input -> case decodeStaticArgs 0 1 input of
          [sk] -> forceConcrete sk "cannot derive address for a symbolic key" $ \sk' -> do
            let a = EVM.Sign.deriveAddr $ into sk'
            case a of
              Nothing -> vmError (BadCheatCode sig)
              Just address -> do
                let expAddr = litAddr address
                assign (#state % #returndata % word256At (Lit 0)) expAddr
                let buf = ConcreteBuf $ word256Bytes (into address)
                copyBytesToMemory buf (Lit 32) (Lit 0) outOffset
          _ -> vmError (BadCheatCode sig),

      action "prank(address)" $
        \sig _ _ input -> case decodeStaticArgs 0 1 input of
          [addr]  -> case wordToAddr addr of
            Just a -> assign (#config % #overrideCaller) (Just a)
            Nothing -> vmError (BadCheatCode sig)
          _ -> vmError (BadCheatCode sig),

      action "createFork(string)" $
        \sig outOffset _ input -> case decodeBuf [AbiStringType] input of
          CAbi valsArr -> case valsArr of
            [AbiString bytes] -> do
              forkId <- length <$> gets (.forks)
              let urlOrAlias = Char8.unpack bytes
              modify' $ \vm -> vm { forks = vm.forks Seq.|> ForkState vm.env vm.block vm.cache urlOrAlias }
              let encoded = encodeAbiValue $ AbiUInt 256 (fromIntegral forkId)
              assign (#state % #returndata) (ConcreteBuf encoded)
              copyBytesToMemory (ConcreteBuf encoded) (Lit . unsafeInto . BS.length $ encoded) (Lit 0) outOffset
            _ -> vmError (BadCheatCode sig)
          _ -> vmError (BadCheatCode sig),

      action "selectFork(uint256)" $
        \sig _ _ input -> case decodeStaticArgs 0 1 input of
          [forkId] ->
            forceConcrete forkId "forkId must be concrete" $ \(fromIntegral -> forkId') -> do
              saved <- Seq.lookup forkId' <$> gets (.forks)
              case saved of
                Just forkState -> do
                  vm <- get
                  case (vm.env.storage, forkState.env.storage) of
                    (ConcreteStore store, ConcreteStore savedStore) -> do
                      let
                        -- the current contract is persited across forks
                        self = vm.state.contract
                        this = fromMaybe (error "internal error: state contract")
                                         (Map.lookup self vm.env.contracts)
                        currStorage = fromMaybe mempty $ Map.lookup (fromIntegral self) store
                        newStore = ConcreteStore $ Map.insert (fromIntegral self) currStorage savedStore
                        newContracts = Map.insert self this forkState.env.contracts
                        newEnv = forkState.env { storage = newStore, contracts = newContracts }

                      when (vm.currentFork /= forkId') $ do
                        modify' $ \vm' -> vm'
                          { env = newEnv
                          , block = forkState.block
                          , forks = Seq.adjust' (\state -> (state :: ForkState)
                              { env = vm.env, block = vm.block, cache = vm.cache }
                            ) vm.currentFork  vm.forks
                          , currentFork = forkId'
                          }
                    _ ->
                      -- no-op: current storage and/or saved storage is symbolic
                      -- we don't support this at the moment
                      pure ()
                Nothing ->
                  pure () -- no-op: fork not found
          _ -> vmError (BadCheatCode sig)
    ]
  where
    action s f = (abiKeccak s, f (abiKeccak s))

-- * General call implementation ("delegateCall")
-- note that the continuation is ignored in the precompile case
delegateCall
  :: (?op :: Word8)
  => Contract -> Word64 -> Expr EAddr -> Expr EAddr -> Expr EWord -> W256 -> W256 -> W256 -> W256
  -> [Expr EWord]
  -> (Expr EAddr -> EVM s ())
  -> EVM s ()
delegateCall this gasGiven xTo xContext xValue xInOffset xInSize xOutOffset xOutSize xs continue
  | isPrecompileAddr xTo
      = forceConcreteAddr2 (xTo, xContext) "Cannot call precompile with symbolic addresses" $
          \(xTo', xContext') ->
            precompiledContract this gasGiven xTo' xContext' xValue xInOffset xInSize xOutOffset xOutSize xs
  | xTo == cheatCode = do
      assign (#state % #stack) xs
      cheat (xInOffset, xInSize) (xOutOffset, xOutSize)
  | otherwise =
      callChecks this gasGiven xContext xTo xValue xInOffset xInSize xOutOffset xOutSize xs $
        \xGas -> do
          vm0 <- get
          fetchAccount xTo $ \target -> case target.code of
              UnknownCode _ -> do
                pc <- use (#state % #pc)
                partial $ UnexpectedSymbolicArg pc "call target has unknown code" (wrap [xTo])
              _ -> do
                burn xGas $ do
                  calldata <- readMemory (Lit xInOffset) (Lit xInSize)
                  abi <- maybeLitWord . readBytes 4 (Lit 0) <$> readMemory (Lit xInOffset) (Lit 4)
                  let newContext = CallContext
                                    { target    = xTo
                                    , context   = xContext
                                    , offset    = xOutOffset
                                    , size      = xOutSize
                                    , codehash  = target.codehash
                                    , callreversion = vm0.env.contracts
                                    , subState  = vm0.tx.substate
                                    , abi
                                    , calldata
                                    }
                  pushTrace (FrameTrace newContext)
                  next
                  vm1 <- get

                  pushTo #frames $ Frame
                    { state = vm1.state { stack = xs }
                    , context = newContext
                    }

                  let clearInitCode = \case
                        (InitCode _ _) -> InitCode mempty mempty
                        a -> a

                  newMemory <- ConcreteMemory <$> VUnboxed.Mutable.new 0
                  zoom #state $ do
                    assign #gas xGas
                    assign #pc 0
                    assign #code (clearInitCode target.code)
                    assign #codeContract xTo
                    assign #stack mempty
                    assign #memory newMemory
                    assign #memorySize 0
                    assign #returndata mempty
                    assign #calldata calldata
                  continue xTo

-- -- * Contract creation

-- EIP 684
collision :: Maybe Contract -> Bool
collision c' = case c' of
  Just c -> c.nonce /= Just 0 || case c.code of
    RuntimeCode (ConcreteRuntimeCode "") -> False
    RuntimeCode (SymbolicRuntimeCode b) -> not $ null b
    _ -> True
  Nothing -> False

create :: (?op :: Word8)
  => Expr EAddr -> Contract
  -> W256 -> Word64 -> Expr EWord -> [Expr EWord] -> Expr EAddr -> Expr Buf -> EVM s ()
create self this xSize xGas xValue xs newAddr initCode = do
  vm0 <- get
  if xSize > vm0.block.maxCodeSize * 2
  then do
    assign (#state % #stack) (Lit 0 : xs)
    assign (#state % #returndata) mempty
    vmError $ MaxInitCodeSizeExceeded (vm0.block.maxCodeSize * 2) xSize
  else if this.nonce == Just maxBound
  then do
    assign (#state % #stack) (Lit 0 : xs)
    assign (#state % #returndata) mempty
    pushTrace $ ErrorTrace NonceOverflow
    next
  else if length vm0.frames >= 1024
  then do
    assign (#state % #stack) (Lit 0 : xs)
    assign (#state % #returndata) mempty
    pushTrace $ ErrorTrace CallDepthLimitReached
    next
  else if collision $ Map.lookup newAddr vm0.env.contracts
  then burn xGas $ do
    assign (#state % #stack) (Lit 0 : xs)
    assign (#state % #returndata) mempty
    modifying (#env % #contracts % ix self % #nonce) (fmap ((+) 1))
    next
  -- do we have enough balance
  else branch (Expr.gt xValue this.balance) $ \case
      True -> do
        assign (#state % #stack) (Lit 0 : xs)
        assign (#state % #returndata) mempty
        pushTrace $ ErrorTrace $ BalanceTooLow xValue this.balance
        next
        touchAccount self
        touchAccount newAddr
      -- are we overflowing the nonce
      False -> burn xGas $ do
        case parseInitCode initCode of
          Nothing ->
            partial $ UnexpectedSymbolicArg vm0.state.pc "initcode must have a concrete prefix" []
          Just c -> do
            let
              newContract = initialContract c
              newContext  =
                CreationContext { address   = newAddr
                                , codehash  = newContract.codehash
                                , createreversion = vm0.env.contracts
                                , substate  = vm0.tx.substate
                                }

            zoom (#env % #contracts) $ do
              oldAcc <- use (at newAddr)
              let oldBal = maybe (Lit 0) (.balance) oldAcc

              assign (at newAddr) (Just (newContract & #balance .~ oldBal))
              modifying (ix self % #nonce) (fmap ((+) 1))

            let
              resetStorage :: Expr Storage -> Expr Storage
              resetStorage = \case
                  ConcreteStore _ -> ConcreteStore mempty
                  AbstractStore a -> AbstractStore a
                  SStore _ _ p -> resetStorage p
                  GVar _  -> error "unexpected global variable"

            modifying (#env % #contracts % ix newAddr % #storage) resetStorage
            modifying (#env % #contracts % ix newAddr % #origStorage) resetStorage

            transfer self newAddr xValue

            pushTrace (FrameTrace newContext)
            next
            vm1 <- get
            pushTo #frames $ Frame
              { context = newContext
              , state   = vm1.state { stack = xs }
              }

            state <- lift blankState
            assign #state $ state
              { contract     = newAddr
              , codeContract = newAddr
              , code         = c
              , callvalue    = xValue
              , caller       = self
              , gas          = xGas
              }

-- | Parses a raw Buf into an InitCode
--
-- solidity implements constructor args by appending them to the end of
-- the initcode. we support this internally by treating initCode as a
-- concrete region (initCode) followed by a potentially symbolic region
-- (arguments).
--
-- when constructing a contract that has symbolic construcor args, we
-- need to apply some heuristics to convert the (unstructured) initcode
-- in memory into this structured representation. The (unsound, bad,
-- hacky) way that we do this, is by: looking for the first potentially
-- symbolic byte in the input buffer and then splitting it there into code / data.
parseInitCode :: Expr Buf -> Maybe ContractCode
parseInitCode (ConcreteBuf b) = Just (InitCode b mempty)
parseInitCode buf = if V.null conc
                    then Nothing
                    else Just $ InitCode (BS.pack $ V.toList conc) sym
  where
    conc = Expr.concretePrefix buf
    -- unsafeInto: findIndex will always be positive
    sym = Expr.drop (unsafeInto (V.length conc)) buf

-- | Replace a contract's code, like when CREATE returns
-- from the constructor code.
replaceCode :: Expr EAddr -> ContractCode -> EVM s ()
replaceCode target newCode =
  zoom (#env % #contracts % at target) $
    get >>= \case
      Just now -> case now.code of
        InitCode _ _ ->
          put . Just $
            ((initialContract newCode) :: Contract)
              { balance = now.balance
              , nonce = now.nonce
              , storage = now.storage
              }
        RuntimeCode _ ->
          internalError $ "Can't replace code of deployed contract " <> show target
        UnknownCode _ ->
          internalError "Can't replace unknown code"
      Nothing ->
        internalError "Can't replace code of nonexistent contract"

replaceCodeOfSelf :: ContractCode -> EVM s ()
replaceCodeOfSelf newCode = do
  vm <- get
  replaceCode vm.state.contract newCode

resetState :: EVM s ()
resetState = do
  state <- lift blankState
  modify' $ \vm -> vm { result = Nothing, frames = [], state }

-- * VM error implementation

vmError :: EvmError -> EVM s ()
vmError e = finishFrame (FrameErrored e)

partial :: PartialExec -> EVM s ()
partial e = assign #result (Just (Unfinished e))

wrap :: Typeable a => [Expr a] -> [SomeExpr]
wrap = fmap SomeExpr

underrun :: EVM s ()
underrun = vmError StackUnderrun

-- | A stack frame can be popped in three ways.
data FrameResult
  = FrameReturned (Expr Buf) -- ^ STOP, RETURN, or no more code
  | FrameReverted (Expr Buf) -- ^ REVERT
  | FrameErrored EvmError -- ^ Any other error
  deriving Show

-- | This function defines how to pop the current stack frame in either of
-- the ways specified by 'FrameResult'.
--
-- It also handles the case when the current stack frame is the only one;
-- in this case, we set the final '_result' of the VM execution.
finishFrame :: FrameResult -> EVM s ()
finishFrame how = do
  oldVm <- get

  case oldVm.frames of
    -- Is the current frame the only one?
    [] -> do
      case how of
          FrameReturned output -> assign #result . Just $ VMSuccess output
          FrameReverted buffer -> assign #result . Just $ VMFailure (Revert buffer)
          FrameErrored e       -> assign #result . Just $ VMFailure e
      finalize

    -- Are there some remaining frames?
    nextFrame : remainingFrames -> do

      -- Insert a debug trace.
      insertTrace $
        case how of
          FrameErrored e ->
            ErrorTrace e
          FrameReverted e ->
            ErrorTrace (Revert e)
          FrameReturned output ->
            ReturnTrace output nextFrame.context
      -- Pop to the previous level of the debug trace stack.
      popTrace

      -- Pop the top frame.
      assign #frames remainingFrames
      -- Install the state of the frame to which we shall return.
      assign #state nextFrame.state

      -- When entering a call, the gas allowance is counted as burned
      -- in advance; this unburns the remainder and adds it to the
      -- parent frame.
      let remainingGas = oldVm.state.gas
          reclaimRemainingGasAllowance = do
            modifying #burned (subtract remainingGas)
            modifying (#state % #gas) (+ remainingGas)

      -- Now dispatch on whether we were creating or calling,
      -- and whether we shall return, revert, or internalError(six cases).
      case nextFrame.context of

        -- Were we calling?
        CallContext _ _ (Lit -> outOffset) (Lit -> outSize) _ _ _ reversion substate' -> do

          -- Excerpt K.1. from the yellow paper:
          -- K.1. Deletion of an Account Despite Out-of-gas.
          -- At block 2675119, in the transaction 0xcf416c536ec1a19ed1fb89e4ec7ffb3cf73aa413b3aa9b77d60e4fd81a4296ba,
          -- an account at address 0x03 was called and an out-of-gas occurred during the call.
          -- Against the equation (197), this added 0x03 in the set of touched addresses, and this transaction turned σ[0x03] into ∅.

          -- In other words, we special case address 0x03 and keep it in the set of touched accounts during revert
          touched <- use (#tx % #substate % #touchedAccounts)

          let
            substate'' = over #touchedAccounts (maybe id cons (find (LitAddr 3 ==) touched)) substate'
            revertContracts = assign (#env % #contracts) reversion
            revertSubstate  = assign (#tx % #substate) substate''

          case how of
            -- Case 1: Returning from a call?
            FrameReturned output -> do
              assign (#state % #returndata) output
              copyCallBytesToMemory output outSize outOffset
              reclaimRemainingGasAllowance
              push 1

            -- Case 2: Reverting during a call?
            FrameReverted output -> do
              revertContracts
              revertSubstate
              assign (#state % #returndata) output
              copyCallBytesToMemory output outSize outOffset
              reclaimRemainingGasAllowance
              push 0

            -- Case 3: Error during a call?
            FrameErrored _ -> do
              revertContracts
              revertSubstate
              assign (#state % #returndata) mempty
              push 0
        -- Or were we creating?
        CreationContext _ _ reversion substate' -> do
          creator <- use (#state % #contract)
          let
            createe = oldVm.state.contract
            revertContracts = assign (#env % #contracts) reversion'
            revertSubstate  = assign (#tx % #substate) substate'

            -- persist the nonce through the reversion
            reversion' = (Map.adjust (over #nonce (fmap ((+) 1))) creator) reversion

          case how of
            -- Case 4: Returning during a creation?
            FrameReturned output -> do
              let onContractCode contractCode = do
                    replaceCode createe contractCode
                    assign (#state % #returndata) mempty
                    reclaimRemainingGasAllowance
                    pushAddr createe
              case output of
                ConcreteBuf bs ->
                  onContractCode $ RuntimeCode (ConcreteRuntimeCode bs)
                _ ->
                  case Expr.toList output of
                    Nothing -> partial $
                      UnexpectedSymbolicArg
                        oldVm.state.pc
                        "runtime code cannot have an abstract length"
                        (wrap [output])
                    Just newCode -> do
                      onContractCode $ RuntimeCode (SymbolicRuntimeCode newCode)

            -- Case 5: Reverting during a creation?
            FrameReverted output -> do
              revertContracts
              revertSubstate
              assign (#state % #returndata) output
              reclaimRemainingGasAllowance
              push 0

            -- Case 6: Error during a creation?
            FrameErrored _ -> do
              revertContracts
              revertSubstate
              assign (#state % #returndata) mempty
              push 0


-- * Memory helpers

accessUnboundedMemoryRange
  :: Word64
  -> Word64
  -> EVM s ()
  -> EVM s ()
accessUnboundedMemoryRange _ 0 continue = continue
accessUnboundedMemoryRange f l continue = do
  m0 <- use (#state % #memorySize)
  fees <- gets (.block.schedule)
  let m1 = 32 * ceilDiv (max m0 (f + l)) 32
  burn (memoryCost fees m1 - memoryCost fees m0) $ do
    assign (#state % #memorySize) m1
    continue

accessMemoryRange
  :: W256
  -> W256
  -> EVM s ()
  -> EVM s ()
accessMemoryRange _ 0 continue = continue
accessMemoryRange offs sz continue =
  case (,) <$> toWord64 offs <*> toWord64 sz of
    Nothing -> vmError IllegalOverflow
    Just (offs64, sz64) ->
      if offs64 + sz64 < sz64
        then vmError IllegalOverflow
        else accessUnboundedMemoryRange offs64 sz64 continue

accessMemoryWord
  :: W256 -> EVM s () -> EVM s ()
accessMemoryWord x = accessMemoryRange x 32

copyBytesToMemory
  :: Expr Buf -> Expr EWord -> Expr EWord -> Expr EWord -> EVM s ()
copyBytesToMemory bs size srcOffset memOffset =
  if size == Lit 0 then noop
  else do
    gets (.state.memory) >>= \case
      ConcreteMemory mem ->
        case (bs, size, srcOffset, memOffset) of
          (ConcreteBuf b, Lit size', Lit srcOffset', Lit memOffset') -> do
            let src =
                  if srcOffset' >= unsafeInto (BS.length b) then
                    BS.replicate (unsafeInto size') 0
                  else
                    BS.take (unsafeInto size') $
                    padRight (unsafeInto size') $
                    BS.drop (unsafeInto srcOffset') b

            writeMemory mem (unsafeInto memOffset') src
          _ -> do
            -- copy out and move to symbolic memory
            buf <- freezeMemory mem
            assign (#state % #memory) $
              SymbolicMemory $ copySlice srcOffset memOffset size bs buf
      SymbolicMemory mem ->
        assign (#state % #memory) $
          SymbolicMemory $ copySlice srcOffset memOffset size bs mem

copyCallBytesToMemory
  :: Expr Buf -> Expr EWord -> Expr EWord -> EVM s ()
copyCallBytesToMemory bs size yOffset =
  copyBytesToMemory bs (Expr.min size (bufLength bs)) (Lit 0) yOffset

readMemory :: Expr EWord -> Expr EWord -> EVM s (Expr Buf)
readMemory offset' size' = do
  vm <- get
  case vm.state.memory of
    ConcreteMemory mem -> do
      case (offset', size') of
        (Lit offset, Lit size) -> do
          let memSize :: Word64 = unsafeInto (VUnboxed.Mutable.length mem)
          if size > Expr.maxBytes ||
             offset + size > Expr.maxBytes ||
             offset >= into memSize then
            -- reads past memory are all zeros
            pure $ ConcreteBuf $ BS.replicate (unsafeInto size) 0
          else do
            let pastEnd = (unsafeInto offset + unsafeInto size) - unsafeInto memSize
            let fromMemSize = if pastEnd > 0 then unsafeInto size - pastEnd else unsafeInto size

            buf <- VUnboxed.freeze $ VUnboxed.Mutable.slice (unsafeInto offset) fromMemSize mem
            let dataFromMem = BS.pack $ VUnboxed.toList buf
            pure $ ConcreteBuf $ dataFromMem <> BS.replicate pastEnd 0
        _ -> do
          buf <- freezeMemory mem
          pure $ copySlice offset' (Lit 0) size' buf mempty
    SymbolicMemory mem ->
      pure $ copySlice offset' (Lit 0) size' mem mempty

-- * Tracing

withTraceLocation :: TraceData -> EVM s Trace
withTraceLocation x = do
  vm <- get
  let this = fromJust $ currentContract vm
  pure Trace
    { tracedata = x
    , contract = this
    , opIx = fromMaybe 0 $ this.opIxMap SV.!? vm.state.pc
    }

pushTrace :: TraceData -> EVM s ()
pushTrace x = do
  trace <- withTraceLocation x
  modifying #traces $
    \t -> Zipper.children $ Zipper.insert (Node trace []) t

insertTrace :: TraceData -> EVM s ()
insertTrace x = do
  trace <- withTraceLocation x
  modifying #traces $
    \t -> Zipper.nextSpace $ Zipper.insert (Node trace []) t

popTrace :: EVM s ()
popTrace =
  modifying #traces $
    \t -> case Zipper.parent t of
            Nothing -> internalError "internal internalError(trace root)"
            Just t' -> Zipper.nextSpace t'

zipperRootForest :: Zipper.TreePos Zipper.Empty a -> Forest a
zipperRootForest z =
  case Zipper.parent z of
    Nothing -> Zipper.toForest z
    Just z' -> zipperRootForest (Zipper.nextSpace z')

traceForest :: VM s -> Forest Trace
traceForest vm = zipperRootForest vm.traces

traceForest' :: Expr End -> Forest Trace
traceForest' (Success _ (Traces f _) _ _) = f
traceForest' (Partial _ (Traces f _) _) = f
traceForest' (Failure _ (Traces f _) _) = f
traceForest' (ITE {}) = internalError"Internal Error: ITE does not contain a trace"
traceForest' (GVar {}) = internalError"Internal Error: Unexpected GVar"

traceContext :: Expr End -> Map (Expr EAddr) Contract
traceContext (Success _ (Traces _ c) _ _) = c
traceContext (Partial _ (Traces _ c) _) = c
traceContext (Failure _ (Traces _ c) _) = c
traceContext (ITE {}) = internalError"Internal Error: ITE does not contain a trace"
traceContext (GVar {}) = internalError"Internal Error: Unexpected GVar"

traceTopLog :: [Expr Log] -> EVM s ()
traceTopLog [] = noop
traceTopLog ((LogEntry addr bytes topics) : _) = do
  trace <- withTraceLocation (EventTrace addr bytes topics)
  modifying #traces $
    \t -> Zipper.nextSpace (Zipper.insert (Node trace []) t)
traceTopLog ((GVar _) : _) = internalError "unexpected global variable"

-- * Stack manipulation

push :: W256 -> EVM s ()
push = pushSym . Lit

pushSym :: Expr EWord -> EVM s ()
pushSym x = #state % #stack %= (x :)

pushAddr :: Expr EAddr -> EVM s ()
pushAddr (LitAddr x) = #state % #stack %= (Lit (into x) :)
pushAddr x@(SymAddr _) = #state % #stack %= (WAddr x :)
pushAddr (GVar _) = internalError "Unexpected GVar"

stackOp1
  :: (?op :: Word8)
  => Word64
  -> (Expr EWord -> Expr EWord)
  -> EVM s ()
stackOp1 cost f =
  use (#state % #stack) >>= \case
    x:xs ->
      burn cost $ do
        next
        let !y = f x
        #state % #stack .= y : xs
    _ ->
      underrun

stackOp2
  :: (?op :: Word8)
  => Word64
  -> (Expr EWord -> Expr EWord -> Expr EWord)
  -> EVM s ()
stackOp2 cost f =
  use (#state % #stack) >>= \case
    x:y:xs ->
      burn cost $ do
        next
        #state % #stack .= f x y : xs
    _ ->
      underrun

stackOp3
  :: (?op :: Word8)
  => Word64
  -> (Expr EWord -> Expr EWord -> Expr EWord -> Expr EWord)
  -> EVM s ()
stackOp3 cost f =
  use (#state % #stack) >>= \case
    x:y:z:xs ->
      burn cost $ do
      next
      (#state % #stack) .= f x y z : xs
    _ ->
      underrun

-- * Bytecode data functions

use' :: (VM s -> a) -> EVM s a
use' f = do
  vm <- get
  pure (f vm)

checkJump :: Int -> [Expr EWord] -> EVM s ()
checkJump x xs = noJumpIntoInitData x $ do
  vm <- get
  case isValidJumpDest vm x of
    True -> do
      #state % #stack .= xs
      #state % #pc .= x
    False -> vmError BadJumpDestination

-- fails with partial if we're trying to jump into the symbolic region of an `InitCode`
noJumpIntoInitData :: Int -> EVM s () -> EVM s ()
noJumpIntoInitData idx cont = do
  vm <- get
  case vm.state.code of
    -- init code is totally concrete, so we don't return partial if we're
    -- jumping beyond the range of `ops`
    InitCode _ (ConcreteBuf "") -> cont
    -- init code has a symbolic region, so check if we're trying to jump into
    -- the symbolic region and return partial if we are
    InitCode ops _ -> if idx > BS.length ops
                      then partial $ JumpIntoSymbolicCode vm.state.pc idx
                      else cont
    -- we're not executing init code, so nothing to check here
    _ -> cont

isValidJumpDest :: VM s -> Int -> Bool
isValidJumpDest vm x = let
    code = vm.state.code
    self = vm.state.codeContract
    contract = fromMaybe
      (internalError "self not found in current contracts")
      (Map.lookup self vm.env.contracts)
    op = case code of
      UnknownCode _ -> internalError "Cannot analyze jumpdests for unknown code"
      InitCode ops _ -> BS.indexMaybe ops x
      RuntimeCode (ConcreteRuntimeCode ops) -> BS.indexMaybe ops x
      RuntimeCode (SymbolicRuntimeCode ops) -> ops V.!? x >>= maybeLitByte
  in case op of
       Nothing -> False
       Just b -> 0x5b == b && OpJumpdest == snd (contract.codeOps V.! (contract.opIxMap SV.! x))

opSize :: Word8 -> Int
opSize x | x >= 0x60 && x <= 0x7f = into x - 0x60 + 2
opSize _                          = 1

--  i of the resulting vector contains the operation index for
-- the program counter value i.  This is needed because source map
-- entries are per operation, not per byte.
mkOpIxMap :: ContractCode -> SV.Vector Int
mkOpIxMap (UnknownCode _) = internalError "Cannot build opIxMap for unknown code"
mkOpIxMap (InitCode conc _)
  = SV.create $ SV.new (BS.length conc) >>= \v ->
      -- Loop over the byte string accumulating a vector-mutating action.
      -- This is somewhat obfuscated, but should be fast.
      let (_, _, _, m) = BS.foldl' (go v) (0 :: Word8, 0, 0, pure ()) conc
      in m >> pure v
      where
        -- concrete case
        go v (0, !i, !j, !m) x | x >= 0x60 && x <= 0x7f =
          {- Start of PUSH op. -} (x - 0x60 + 1, i + 1, j,     m >> SV.write v i j)
        go v (1, !i, !j, !m) _ =
          {- End of PUSH op. -}   (0,            i + 1, j + 1, m >> SV.write v i j)
        go v (0, !i, !j, !m) _ =
          {- Other op. -}         (0,            i + 1, j + 1, m >> SV.write v i j)
        go v (n, !i, !j, !m) _ =
          {- PUSH data. -}        (n - 1,        i + 1, j,     m >> SV.write v i j)

mkOpIxMap (RuntimeCode (ConcreteRuntimeCode ops)) =
  mkOpIxMap (InitCode ops mempty) -- a bit hacky

mkOpIxMap (RuntimeCode (SymbolicRuntimeCode ops))
  = SV.create $ SV.new (length ops) >>= \v ->
      let (_, _, _, m) = foldl (go v) (0, 0, 0, pure ()) (stripBytecodeMetadataSym $ V.toList ops)
      in m >> pure v
      where
        go v (0, !i, !j, !m) x = case maybeLitByte x of
          Just x' -> if x' >= 0x60 && x' <= 0x7f
            -- start of PUSH op --
                     then (x' - 0x60 + 1, i + 1, j,     m >> SV.write v i j)
            -- other data --
                     else (0,             i + 1, j + 1, m >> SV.write v i j)
          _ -> internalError $ "cannot analyze symbolic code:\nx: " <> show x <> " i: " <> show i <> " j: " <> show j

        go v (1, !i, !j, !m) _ =
          {- End of PUSH op. -}   (0,            i + 1, j + 1, m >> SV.write v i j)
        go v (n, !i, !j, !m) _ =
          {- PUSH data. -}        (n - 1,        i + 1, j,     m >> SV.write v i j)


vmOp :: VM s -> Maybe Op
vmOp vm =
  let i  = vm ^. #state % #pc
      code' = vm ^. #state % #code
      (op, pushdata) = case code' of
        UnknownCode _ -> internalError "cannot get op from unknown code"
        InitCode xs' _ ->
          (BS.index xs' i, fmap LitByte $ BS.unpack $ BS.drop i xs')
        RuntimeCode (ConcreteRuntimeCode xs') ->
          (BS.index xs' i, fmap LitByte $ BS.unpack $ BS.drop i xs')
        RuntimeCode (SymbolicRuntimeCode xs') ->
          ( fromMaybe (internalError "unexpected symbolic code") . maybeLitByte $ xs' V.! i , V.toList $ V.drop i xs')
  in if (opslen code' < i)
     then Nothing
     else Just (readOp op pushdata)

vmOpIx :: VM s -> Maybe Int
vmOpIx vm =
  do self <- currentContract vm
     self.opIxMap SV.!? vm.state.pc

-- Maps operation indicies into a pair of (bytecode index, operation)
mkCodeOps :: ContractCode -> V.Vector (Int, Op)
mkCodeOps contractCode =
  let l = case contractCode of
            UnknownCode _ -> internalError "Cannot make codeOps for unknown code"
            InitCode bytes _ ->
              LitByte <$> (BS.unpack bytes)
            RuntimeCode (ConcreteRuntimeCode ops) ->
              LitByte <$> (BS.unpack $ stripBytecodeMetadata ops)
            RuntimeCode (SymbolicRuntimeCode ops) ->
              stripBytecodeMetadataSym $ V.toList ops
  in V.fromList . toList $ go 0 l
  where
    go !i !xs =
      case uncons xs of
        Nothing ->
          mempty
        Just (x, xs') ->
          let x' = fromMaybe (internalError "unexpected symbolic code argument") $ maybeLitByte x
              j = opSize x'
          in (i, readOp x' xs') Seq.<| go (i + j) (drop j xs)

-- * Gas cost calculation helpers

-- Gas cost function for CALL, transliterated from the Yellow Paper.
costOfCall
  :: FeeSchedule Word64
  -> Bool -> Expr EWord -> Word64 -> Word64 -> Expr EAddr
  -> EVM s (Word64, Word64)
costOfCall (FeeSchedule {..}) recipientExists (Lit xValue) availableGas xGas target = do
  acc <- accessAccountForGas target
  let call_base_gas = if acc then g_warm_storage_read else g_cold_account_access
      c_new = if not recipientExists && xValue /= 0
            then g_newaccount
            else 0
      c_xfer = if xValue /= 0  then g_callvalue else 0
      c_extra = call_base_gas + c_xfer + c_new
      c_gascap =  if availableGas >= c_extra
                  then min xGas (allButOne64th (availableGas - c_extra))
                  else xGas
      c_callgas = if xValue /= 0 then c_gascap + g_callstipend else c_gascap
  pure (c_gascap + c_extra, c_callgas)
-- calls are free if value is symbolic :)
costOfCall _ _ _ _ _ _ = pure (0,0)

-- Gas cost of create, including hash cost if needed
costOfCreate
  :: FeeSchedule Word64
  -> Word64 -> W256 -> Bool -> (Word64, Word64)
costOfCreate (FeeSchedule {..}) availableGas size hashNeeded = (createCost, initGas)
  where
    byteCost   = if hashNeeded then g_sha3word + g_initcodeword else g_initcodeword
    createCost = g_create + codeCost
    codeCost   = byteCost * (ceilDiv (unsafeInto size) 32)
    initGas    = allButOne64th (availableGas - createCost)

concreteModexpGasFee :: ByteString -> Word64
concreteModexpGasFee input =
  if lenb < into (maxBound :: Word32) &&
     (lene < into (maxBound :: Word32) || (lenb == 0 && lenm == 0)) &&
     lenm < into (maxBound :: Word64)
  then
    max 200 ((multiplicationComplexity * iterCount) `div` 3)
  else
    maxBound -- TODO: this is not 100% correct, return Nothing on overflow
  where
    (lenb, lene, lenm) = parseModexpLength input
    ez = isZero (96 + lenb) lene input
    e' = word $ LS.toStrict $
      lazySlice (96 + lenb) (min 32 lene) input
    nwords :: Word64
    nwords = ceilDiv (unsafeInto $ max lenb lenm) 8
    multiplicationComplexity = nwords * nwords
    iterCount' :: Word64
    iterCount' | lene <= 32 && ez = 0
               | lene <= 32 = unsafeInto (log2 e')
               | e' == 0 = 8 * (unsafeInto lene - 32)
               | otherwise = unsafeInto (log2 e') + 8 * (unsafeInto lene - 32)
    iterCount = max iterCount' 1

-- Gas cost of precompiles
costOfPrecompile :: FeeSchedule Word64 -> Addr -> Expr Buf -> Word64
costOfPrecompile (FeeSchedule {..}) precompileAddr input =
  let errorDynamicSize = internalError "precompile input cannot have a dynamic size"
      inputLen = case input of
                   ConcreteBuf bs -> unsafeInto $ BS.length bs
                   AbstractBuf _ -> errorDynamicSize
                   buf -> case bufLength buf of
                            Lit l -> unsafeInto l -- TODO: overflow
                            _ -> errorDynamicSize
  in case precompileAddr of
    -- ECRECOVER
    0x1 -> 3000
    -- SHA2-256
    0x2 -> (((inputLen + 31) `div` 32) * 12) + 60
    -- RIPEMD-160
    0x3 -> (((inputLen + 31) `div` 32) * 120) + 600
    -- IDENTITY
    0x4 -> (((inputLen + 31) `div` 32) * 3) + 15
    -- MODEXP
    0x5 -> case input of
             ConcreteBuf i -> concreteModexpGasFee i
             _ -> internalError "Unsupported symbolic modexp gas calc "
    -- ECADD
    0x6 -> g_ecadd
    -- ECMUL
    0x7 -> g_ecmul
    -- ECPAIRING
    0x8 -> (inputLen `div` 192) * g_pairing_point + g_pairing_base
    -- BLAKE2
    0x9 -> case input of
             ConcreteBuf i -> g_fround * (unsafeInto $ asInteger $ lazySlice 0 4 i)
             _ -> internalError "Unsupported symbolic blake2 gas calc"
    _ -> internalError $ "unimplemented precompiled contract " ++ show precompileAddr

-- Gas cost of memory expansion
memoryCost :: FeeSchedule Word64 -> Word64 -> Word64
memoryCost FeeSchedule{..} byteCount =
  let
    wordCount = ceilDiv byteCount 32
    linearCost = g_memory * wordCount
    quadraticCost = div (wordCount * wordCount) 512
  in
    linearCost + quadraticCost

hashcode :: ContractCode -> Expr EWord
hashcode (UnknownCode a) = CodeHash a
hashcode (InitCode ops args) = keccak $ (ConcreteBuf ops) <> args
hashcode (RuntimeCode (ConcreteRuntimeCode ops)) = keccak (ConcreteBuf ops)
hashcode (RuntimeCode (SymbolicRuntimeCode ops)) = keccak . Expr.fromList $ ops

-- | The length of the code ignoring any constructor args.
-- This represents the region that can contain executable opcodes
opslen :: ContractCode -> Int
opslen (UnknownCode _) = internalError "Cannot produce concrete opslen for unknown code"
opslen (InitCode ops _) = BS.length ops
opslen (RuntimeCode (ConcreteRuntimeCode ops)) = BS.length ops
opslen (RuntimeCode (SymbolicRuntimeCode ops)) = length ops

-- | The length of the code including any constructor args.
-- This can return an abstract value
codelen :: ContractCode -> Expr EWord
codelen (UnknownCode a) = CodeSize a
codelen c@(InitCode {}) = case toBuf c of
  Just b -> bufLength b
  Nothing -> internalError "impossible"
-- these are never going to be negative so unsafeInto is fine here
codelen (RuntimeCode (ConcreteRuntimeCode ops)) = Lit . unsafeInto $ BS.length ops
codelen (RuntimeCode (SymbolicRuntimeCode ops)) = Lit . unsafeInto $ length ops

toBuf :: ContractCode -> Maybe (Expr Buf)
toBuf (UnknownCode _) = Nothing
toBuf (InitCode ops args) = Just $ ConcreteBuf ops <> args
toBuf (RuntimeCode (ConcreteRuntimeCode ops)) = Just $ ConcreteBuf ops
toBuf (RuntimeCode (SymbolicRuntimeCode ops)) = Just $ Expr.fromList ops

codeloc :: EVM s CodeLocation
codeloc = do
  vm <- get
  pure (vm.state.contract, vm.state.pc)

createAddress :: Expr EAddr -> Maybe W64 -> EVM s (Expr EAddr)
createAddress (LitAddr a) (Just n) = pure $ Concrete.createAddress a n
createAddress (GVar _) _ = internalError "Unexpected GVar"
createAddress _ _ = freshSymAddr

create2Address :: Expr EAddr -> W256 -> ByteString -> EVM s (Expr EAddr)
create2Address (LitAddr a) s b = pure $ Concrete.create2Address a s b
create2Address (SymAddr _) _ _ = freshSymAddr
create2Address (GVar _) _ _ = internalError "Unexpected GVar"

freshSymAddr :: EVM s (Expr EAddr)
freshSymAddr = do
  modifying (#env % #freshAddresses) (+ 1)
  n <- use (#env % #freshAddresses)
  pure $ SymAddr ("freshSymAddr" <> (pack $ show n))

isPrecompileAddr :: Expr EAddr -> Bool
isPrecompileAddr = \case
  LitAddr a -> 0x0 < a && a <= 0x09
  SymAddr _ -> False
  GVar _ -> internalError "Unexpected GVar"

-- * Arithmetic

ceilDiv :: (Num a, Integral a) => a -> a -> a
ceilDiv m n = div (m + n - 1) n

allButOne64th :: (Num a, Integral a) => a -> a
allButOne64th n = n - div n 64

log2 :: FiniteBits b => b -> Int
log2 x = finiteBitSize x - 1 - countLeadingZeros x

writeMemory :: MutableMemory s -> Int -> ByteString -> EVM s ()
writeMemory memory offset buf = do
  memory' <- expandMemory (offset + BS.length buf)
  mapM_ (uncurry (VUnboxed.Mutable.write memory'))
        (zip [offset..] (BS.unpack buf))
  where
  expandMemory targetSize = do
    let toAlloc = targetSize - VUnboxed.Mutable.length memory
    if toAlloc > 0 then do
      memory' <- VUnboxed.Mutable.grow memory toAlloc
      assign (#state % #memory) (ConcreteMemory memory')
      pure memory'
    else
      pure memory

freezeMemory :: MutableMemory s -> EVM s (Expr Buf)
freezeMemory memory =
  ConcreteBuf . BS.pack . VUnboxed.toList <$> VUnboxed.freeze memory
