{-# LANGUAGE
TemplateHaskell,
TypeFamilies,
TupleSections,
MultiParamTypeClasses,
FunctionalDependencies,
FlexibleInstances,
OverloadedStrings,
GeneralizedNewtypeDeriving,
FlexibleContexts,
RankNTypes,
NoImplicitPrelude
  #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}


module DB
(
  -- * Types
  Session,
  User(..),
    nick,
    name,
    email,
    pass,
    admin,
  WordReq(..),
    submitted,
    perUser,
  Game(..),
    title,
    createdBy,
    registerUntil,
    begun,
    ended,
    wordReq,
    groups,
    pastPhases,
    currentPhase,
  Phase(..),
    timePerRound,
  PhaseResults(..),
    winners,
  Round(..),
    score,
    namerPenalty,
    guesserPenalty,
    discards,
  ScheduleStatus(..),
  Timer(..),
  CurrentRound(..),
    timer,
  Room(..),
    currentRound,
    absentees,
    remainingPlayers,
    filteredPastGames,
    table,
    pastGames,
    schedule,
  GlobalState(..),
    games,
    rooms,
    users,
    sessions,
    dirty,
  DB,

  -- * Common lenses
  uid,
  created,
  players,

  -- * Stuff
  emptyState,
  userById,
  mkSchedule,
  execCommand,
  reschedule,

  -- * Methods
  GetGlobalState(..),
  GetSessions(..), SetSessions(..),
  AddUser(..),
  AddPlayer(..), RemovePlayer(..),
  GetUser(..),
  GetUserByNick(..), GetUserByNick'(..),
  SetAdmin(..),
  AddGame(..),
  GetGame(..),
  SetGameBegun(..),
  SetGameGroups(..),
  SetGameCurrentPhase(..),
  StartRound(..),
  SetRoundResults(..),
  SetAbsent(..),
  SetWords(..),
  AdvanceSchedule(..),
  SetDirty(..), UnsetDirty(..),
)
where


-- General
import BasePrelude
-- Monads
import Control.Monad.State
-- Lenses
import Lens.Micro.Platform hiding ((&))
-- Containers
import Data.Map (Map)
import qualified Data.Set as S
import Data.Set (Set)
import qualified Data.Vector.Unboxed as U
-- Text
import qualified Data.Text.All as T
import Data.Text.All (Text)
-- Randomness
import Control.Monad.Random
import System.Random.Shuffle
-- Time
import Data.Time
-- Web
import Web.Spock (SessionId)
-- acid-state
import Data.Acid as Acid
import Data.SafeCopy
-- Passwords
import Crypto.Scrypt
-- Command-line parsing
import Options.Applicative.Simple
-- Exception handling
import Control.Exception.Enclosed

-- Local
import Utils
import Schedule


data User = User {
  _userUid :: Uid User,
  _userNick :: Text,
  _userName :: Text,
  _userEmail :: Text,
  _userCreated :: UTCTime,
  _userPass :: EncryptedPass,
  _userAdmin :: Bool }
  deriving (Show)

type Session = Maybe (Uid User)

data WordReq = WordReq {
  -- | Already submitted words
  _wordReqSubmitted :: Map (Uid User) (Set Text),
  -- | How many words each user should submit
  _wordReqPerUser :: Int }
  deriving (Show)

data Round
  = RoundNotYetPlayed
  | RoundPlayed {
      _roundScore          :: Int,
      _roundNamerPenalty   :: Int,
      _roundGuesserPenalty :: Int,
      _roundDiscards       :: Int }
  | RoundImpossible            -- e.g. the user can't play against themself
  deriving (Show)

data ScheduleStatus
  = ScheduleCalculating PartialSchedule
  | ScheduleDone [(Uid User, Uid User)]
  deriving (Show)

data Phase = Phase {
  -- | In seconds
  _phaseTimePerRound :: Int,
  _phaseRooms :: [Room] }
  deriving (Show)

data PhaseResults = Results {
  _phaseResultsWinners :: [[Uid User]] }
  deriving (Show)

data CurrentRound = CurrentRound {
  _currentRoundPlayers :: (Uid User, Uid User),
  _currentRoundScore :: Int,
  _currentRoundNamerPenalty :: Int,
  _currentRoundGuesserPenalty :: Int,
  _currentRoundDiscards :: Int,
  _currentRoundTimer :: Timer }
  deriving (Show)

data Timer
  = TimerGoing UTCTime    -- when the timer will end
  | TimerPaused Int       -- how many seconds are left
  deriving (Show)

data Room = Room {
  _roomCurrentRound :: Maybe CurrentRound,
  _roomPlayers :: [Uid User],
  _roomAbsentees :: Set (Uid User),
  -- namer, guesser
  _roomTable :: Map (Uid User, Uid User) Round,
  -- | History of past games. Might be inaccunrate because of manual editing,
  -- but is guaranteed to include all played games in the 'table' and not
  -- include any of the not-played games.
  _roomPastGames :: [(Uid User, Uid User)],
  _roomSchedule :: ScheduleStatus }
  deriving (Show)

data Game = Game {
  _gameUid :: Uid Game,
  _gameTitle :: Text,
  _gameCreatedBy :: Uid User,
  _gameWordReq :: Maybe WordReq,
  _gameRegisterUntil :: UTCTime,
  _gameBegun :: Bool,
  _gameEnded :: Bool,
  _gamePlayers :: Set (Uid User),
  -- | A generated division of players into groups
  _gameGroups :: Maybe [[Uid User]],
  _gamePastPhases :: [(Phase, PhaseResults)],
  _gameCurrentPhase :: Maybe Phase }
  deriving (Show)

deriveSafeCopySimple 0 'base ''User
deriveSafeCopySimple 0 'base ''WordReq
deriveSafeCopySimple 0 'base ''Round
deriveSafeCopySimple 0 'base ''ScheduleStatus
deriveSafeCopySimple 0 'base ''Phase
deriveSafeCopySimple 0 'base ''PhaseResults
deriveSafeCopySimple 0 'base ''Timer
deriveSafeCopySimple 0 'base ''CurrentRound
deriveSafeCopySimple 0 'base ''Room
deriveSafeCopySimple 0 'base ''Game

makeFields ''User
makeFields ''WordReq
makeFields ''Round
makeFields ''ScheduleStatus
makeFields ''Phase
makeFields ''PhaseResults
makeFields ''CurrentRound
makeFields ''Room
makeFields ''Game

remainingPlayers :: SimpleGetter Room [Uid User]
remainingPlayers = to $ \room -> room^.players \\ S.toList (room^.absentees)

filteredPastGames :: SimpleGetter Room [(Uid User, Uid User)]
filteredPastGames = to $ \room ->
  filter (\(a,b) -> all (`S.notMember` (room^.absentees)) [a,b])
         (room^.pastGames)

intPastGames :: Room -> U.Vector (Int, Int)
intPastGames room =
  let rp = room^.remainingPlayers
      playerIndex p = fromJust (elemIndex p rp)
  in  U.fromList (room^.filteredPastGames & each.each %~ playerIndex)

data GlobalState = GlobalState {
  _globalStateUsers    :: [User],
  _globalStateGames    :: [Game],
  _globalStateSessions :: [(SessionId, UTCTime, Session)],
  _globalStateDirty    :: Bool }
  deriving (Show)

deriveSafeCopySimple 0 'base ''GlobalState
makeFields ''GlobalState

type DB = AcidState GlobalState

hasUid :: HasUid a (Uid u) => Uid u -> a -> Bool
hasUid u x = x^.uid == u

userById :: Uid User -> Lens' GlobalState User
userById uid' = singular $
  users.each . filtered (hasUid uid') `failing`
  error ("userById: couldn't find user with uid " ++
         T.unpack (uidToText uid'))

userByNick :: Text -> Lens' GlobalState User
userByNick nick' = singular $
  userByNick' nick' `failing`
  error ("userById: couldn't find user with nick " ++
         T.unpack nick')

userByNick' :: Text -> Traversal' GlobalState User
userByNick' nick' = users.each . filtered ((== nick') . view nick)

gameById :: Uid Game -> Lens' GlobalState Game
gameById uid' = singular $
  games.each . filtered (hasUid uid') `failing`
  error ("gameById: couldn't find game with uid " ++
         T.unpack (uidToText uid'))

emptyState :: GlobalState
emptyState = GlobalState {
  _globalStateUsers = [],
  _globalStateGames = [],
  _globalStateSessions = [],
  _globalStateDirty = True }

-- | A useful lens operator that modifies something and returns the old value.
(<<.=) :: MonadState s m => LensLike ((,) a) s s a b -> b -> m a
(<<.=) l b = state (l (,b))
{-# INLINE (<<.=) #-}
infix 4 <<.=

getGlobalState :: Acid.Query GlobalState GlobalState
getGlobalState = view id

getSessions :: Acid.Query GlobalState [(SessionId, UTCTime, Session)]
getSessions = view sessions

setSessions :: [(SessionId, UTCTime, Session)] -> Acid.Update GlobalState ()
setSessions x = sessions .= x

addUser
  :: Uid User       -- ^ New user's uid
  -> Text           -- ^ Nick
  -> Text           -- ^ Name
  -> EncryptedPass  -- ^ Pass
  -> Text           -- ^ Email
  -> UTCTime        -- ^ Creation time
  -> Acid.Update GlobalState User
addUser uid' nick' name' pass' email' now = do
  let user = User {
        _userUid = uid',
        _userNick = nick',
        _userName = name',
        _userEmail = email',
        _userCreated = now,
        _userPass = pass',
        _userAdmin = False }
  users %= (user:)
  return user

addPlayer :: Uid Game -> Uid User -> Acid.Update GlobalState ()
addPlayer gameId userId = do
  gameById gameId . players %= S.insert userId
  gameById gameId . groups .= Nothing

removePlayer :: Uid Game -> Uid User -> Acid.Update GlobalState ()
removePlayer gameId userId = do
  gameById gameId . players %= S.delete userId
  gameById gameId . wordReq . _Just . submitted . at userId .= Nothing
  gameById gameId . groups .= Nothing

getUser :: Uid User -> Acid.Query GlobalState User
getUser uid' = view (userById uid')

getUserByNick :: Text -> Acid.Query GlobalState User
getUserByNick nick' = view (userByNick nick')

getUserByNick' :: Text -> Acid.Query GlobalState (Maybe User)
getUserByNick' nick' = preview (userByNick' nick')

setAdmin :: Uid User -> Bool -> Acid.Update GlobalState ()
setAdmin userId adm = userById userId . admin .= adm

addGame
  :: Uid Game           -- ^ Uid
  -> Text               -- ^ Title
  -> Uid User           -- ^ Created by
  -> Maybe WordReq      -- ^ Word requirements
  -> UTCTime            -- ^ “Register until”
  -> Set (Uid User)     -- ^ Initial set of players
  -> Acid.Update GlobalState Game
addGame uid' title' createdBy' wordReq' registerUntil' players' = do
  let game' = Game {
        _gameUid = uid',
        _gameTitle = title',
        _gameCreatedBy = createdBy',
        _gameWordReq = wordReq',
        _gameRegisterUntil = registerUntil',
        _gameBegun = False,
        _gameEnded = False,
        _gamePlayers = players',
        _gameGroups = Nothing,
        _gamePastPhases = mempty,
        _gameCurrentPhase = Nothing }
  games %= (game':)
  return game'

getGame :: Uid Game -> Acid.Query GlobalState Game
getGame uid' = view (gameById uid')

setGameBegun :: Uid Game -> Bool -> Acid.Update GlobalState ()
setGameBegun gameId val = gameById gameId . begun .= val

setGameGroups :: Uid Game -> Maybe [[Uid User]] -> Acid.Update GlobalState ()
setGameGroups gameId val = gameById gameId . groups .= val

setGameCurrentPhase :: Uid Game -> Phase -> Acid.Update GlobalState ()
setGameCurrentPhase gameId val = gameById gameId . currentPhase .= Just val

startRound
  :: Uid Game
  -> Int                    -- ^ Room
  -> UTCTime                -- ^ Current time
  -> Acid.Update GlobalState ()
startRound gameId roomNum now = do
  let phaseLens :: Lens' GlobalState Phase
      phaseLens = singular $ gameById gameId.currentPhase._Just
      roomLens :: Lens' Phase Room
      roomLens = singular $ rooms.ix (roomNum-1)
  phase' <- use phaseLens
  let room = phase'^.roomLens
  let timerEnd = fromIntegral (phase'^.timePerRound) `addUTCTime` now
  phaseLens.roomLens.currentRound .= Just CurrentRound {
    _currentRoundPlayers = case room^.schedule of
        ScheduleCalculating{} -> error "startRound: no schedule"
        ScheduleDone [] -> error "startRound: no rounds"
        ScheduleDone (x:_) -> x,
    _currentRoundScore = 0,
    _currentRoundNamerPenalty = 0,
    _currentRoundGuesserPenalty = 0,
    _currentRoundDiscards = 0,
    _currentRoundTimer = TimerGoing timerEnd }

setRoundResults
  :: Uid Game
  -> Int                    -- ^ Phase
  -> Int                    -- ^ Room
  -> (Uid User, Uid User)   -- ^ Namer, guesser
  -> Round                  -- ^ Round
  -> Acid.Update GlobalState ()
setRoundResults gameId phaseNum roomNum pls roundRes = do
  game' <- use (gameById gameId)
  let phaseLens :: Traversal' Game Phase
      phaseLens
        | 1 <= phaseNum && phaseNum <= length (game'^.pastPhases) =
            pastPhases . ix (phaseNum-1) . _1
        | phaseNum == length (game'^.pastPhases) + 1 =
            currentPhase . _Just
        | otherwise =
            const pure    -- a traversal that doesn't traverse anything
  let roomLens :: Lens' GlobalState Room
      roomLens = singular $ gameById gameId.phaseLens.rooms.ix (roomNum-1)
  old <- roomLens.table.at pls <<.= Just roundRes
  -- Now we have to update 'pastGames' and the schedule
  room <- use roomLens
  case (fromMaybe RoundNotYetPlayed old, roundRes) of
    (RoundNotYetPlayed, RoundPlayed{}) -> do
      roomLens.pastGames %= (<> [pls])
      case room^.schedule of
        ScheduleCalculating _ -> return ()
        ScheduleDone sch ->
          roomLens.schedule .= ScheduleDone (delete pls sch)
    (RoundImpossible, RoundPlayed{}) -> do
      roomLens.pastGames %= (<> [pls])
      case room^.schedule of
        ScheduleCalculating _ -> return ()
        ScheduleDone sch ->
          roomLens.schedule .= ScheduleDone (delete pls sch)
    (RoundPlayed{}, RoundNotYetPlayed) -> do
      roomLens.pastGames %= delete pls
      case room^.schedule of
        ScheduleCalculating _ -> return ()
        ScheduleDone sch ->
          roomLens.schedule .= ScheduleDone (sch ++ [pls])
    (RoundPlayed{}, RoundImpossible) ->
      roomLens.pastGames %= delete pls
    _other -> return ()

setAbsent
  :: Uid Game
  -> Int                    -- ^ Phase
  -> Int                    -- ^ Room
  -> Uid User               -- ^ Player
  -> Bool
  -> Acid.Update GlobalState ()
setAbsent gameId phaseNum roomNum playerId val = do
  game' <- use (gameById gameId)
  -- TODO: factor this out (it's copied from setRoundResults)
  let phaseLens :: Traversal' Game Phase
      phaseLens
        | 1 <= phaseNum && phaseNum <= length (game'^.pastPhases) =
            pastPhases . ix (phaseNum-1) . _1
        | phaseNum == length (game'^.pastPhases) + 1 =
            currentPhase . _Just
        | otherwise =
            const pure    -- a traversal that doesn't traverse anything
  let roomLens :: Lens' GlobalState Room
      roomLens = singular $ gameById gameId.phaseLens.rooms.ix (roomNum-1)
  if val then roomLens.absentees %= S.insert playerId
         else roomLens.absentees %= S.delete playerId

setWords :: Uid Game -> Uid User -> [Text] -> Acid.Update GlobalState ()
setWords gameId userId ws =
  gameById gameId.wordReq._Just.submitted.at userId .= Just (S.fromList ws)

mkSchedule :: [Uid User] -> Schedule -> [(Uid User, Uid User)]
mkSchedule players' sch = U.toList sch & each.each %~ (players'!!)

advanceSchedule
  :: Uid Game
  -> Int
  -> PartialSchedule
  -> Either PartialSchedule Schedule
  -> Acid.Update GlobalState ()
advanceSchedule gameId roomNum ps ps' = do
  let roomLens :: Lens' GlobalState Room
      roomLens = singular $
        gameById gameId.currentPhase._Just.rooms.ix (roomNum-1)
  room <- use roomLens
  roomLens.schedule .= case room^.schedule of
    ScheduleCalculating s
      | s /= ps   -> room^.schedule
      | otherwise -> case ps' of
          Left  x -> ScheduleCalculating x
          Right x -> ScheduleDone (mkSchedule (room^.remainingPlayers) x)
    ScheduleDone _ -> room^.schedule

setPartialSchedule
  :: Uid Game
  -> Int
  -> [Uid User]                    -- ^ Non-absent players
  -> [(Uid User, Uid User)]        -- ^ Past games of non-absent players
  -> Schedule
  -> Acid.Update GlobalState ()
setPartialSchedule gameId roomNum players' pastGames' sch = do
  let roomLens :: Lens' GlobalState Room
      roomLens = singular $
        gameById gameId.currentPhase._Just.rooms.ix (roomNum-1)
  room <- use roomLens
  let playerCount = length players'
      roundsLeft = playerCount*(playerCount-1) - length pastGames'
      iters | roundsLeft <= 3 = 50000
            | roundsLeft <= 6 = 100000
            | otherwise       = 400000
  when (room^.remainingPlayers == players' &&
        room^.filteredPastGames == pastGames') $
    roomLens.schedule .= ScheduleCalculating (PartialSchedule {
      _schPlayerCount = playerCount,
      _schPastGames = intPastGames room,
      _schCurrent = sch,
      _schBest = sch,
      _schIterationsTotal = iters,
      _schIterationsLeft = iters })

setDirty :: Acid.Update GlobalState ()
setDirty = dirty .= True

unsetDirty :: Acid.Update GlobalState Bool
unsetDirty = dirty <<.= False

makeAcidic ''GlobalState [
  'getGlobalState,
  'getSessions, 'setSessions,
  'addUser,
  'addPlayer, 'removePlayer,
  'getUser,
  'getUserByNick, 'getUserByNick',
  'setAdmin,
  'addGame,
  'getGame,
  'setGameBegun,
  'setGameGroups,
  'setGameCurrentPhase,
  'startRound,
  'setRoundResults,
  'setAbsent,
  'setWords,
  'advanceSchedule,
  'setPartialSchedule,
  'setDirty, 'unsetDirty
  ]

reschedule :: DB -> Uid Game -> Int -> IO ()
reschedule db gameId roomNum = do
  game' <- Acid.query db (GetGame gameId)
  let room = game'^?!currentPhase._Just.rooms.ix (roomNum-1)
  sch <- randomSchedule (length (room^.remainingPlayers))
                        (intPastGames room)
  Acid.update db $
    SetPartialSchedule gameId roomNum
      (room^.remainingPlayers) (room^.filteredPastGames) sch

execCommand :: DB -> String -> IO ()
execCommand db s = do
  let res = execParserPure (prefs showHelpOnError) parserInfo (breakArgs s)
  case res of
    Success ((), io) -> catchAny io $ \e ->
      if isJust (fromException e :: Maybe ExitCode)
        then throwIO e
        else print e
    Failure f -> do
      let (msg, _) = renderFailure f ""
      putStrLn msg
    CompletionInvoked _ -> error "completion invoked"
  where
    breakArgs "" = []
    breakArgs (x:xs)
      | x == '"'  = let (l, r) = break (== '"') xs
                    in read (x:l++"\"") : breakArgs (drop 1 r)
      | isSpace x = breakArgs xs
      | otherwise = let (l, r) = break (\c -> isSpace c || c == '"') xs
                    in (x:l) : breakArgs r

    userArg = argument
      (do input <- T.pack <$> str
          return $ case T.stripPrefix "id:" input of
            Nothing -> Right input
            Just x  -> Left (Uid x))
      (metavar "(NICK|id:ID)")
    gameArg = Uid . T.pack <$> strArgument (metavar "GAME")

    findUser = either (Acid.query db . GetUser)
                      (Acid.query db . GetUserByNick)

    addCommand' cmd descr act = addCommand cmd descr (const act) (pure ())

    parserInfo = info parser mempty
    parser = simpleParser (pure ()) $ do

      addCommand' "exit"
        "Stop the server"
        (exitSuccess)

      addCommand' "sessions"
        "Print open sessions"
        (do ss <- Acid.query db GetSessions
            for_ ss $ \(_, time, content) -> do
              printf "  * %s: %s\n" (show time) (show content)
        )

      addCommand "user"
        "Show information about a user"
        (\u -> do
            user <- findUser u
            printf "%s (%s)\n" (user^.name) (user^.nick)
            printf "\n"
            printf "  * uid       %s\n" (uidToText (user^.uid))
            printf "  * email     %s\n" (user^.email)
            printf "  * created   %s\n" (show (user^.created))
            printf "  * admin     %s\n" (show (user^.admin))
        )
        userArg

      addCommand' "users"
        "List users"
        (do us <- view users <$> Acid.query db GetGlobalState
            for_ us $ \u ->
              printf "  * %s (%s)\n" (u^.name) (u^.nick)
        )

      addCommand "users.add"
        "Create a new user"
        (\(nick', name', pass', email') -> do
            uid' <- randomShortUid
            now  <- getCurrentTime
            encPass <- encryptPassIO' (Pass (T.encodeUtf8 pass'))
            Acid.update db $
              AddUser uid' nick' name' encPass email' now
            printf "uid: %s\n" (uidToText uid')
        )
        (fmap (each %~ T.pack) $
           (,,,) <$> strArgument (metavar "NICK")
                 <*> strArgument (metavar "NAME")
                 <*> strArgument (metavar "PASS")
                 <*> strArgument (metavar "EMAIL"))

      addCommand' "games"
        "List games"
        (do gs <- view games <$> Acid.query db GetGlobalState
            for_ gs $ \g ->
              printf "  * %s (%s)\n" (g^.title) (uidToText (g^.uid))
        )

      addCommand "game.reg"
        "Register a user for the game"
        (\(g, u) -> do
            user <- findUser u
            Acid.update db (AddPlayer g (user^.uid))
        )
        ((,) <$> gameArg <*> userArg)

      addCommand' "populate"
        "Generate random users and games"
        (do -- generating users
            putStrLn "Generating users u{0..199}"
            putStrLn "(passwords = nicks; users 0..19 are admins)"
            generatedUsers <- for [0..199::Int] $ \i -> do
              let nick' = T.format "u{}" [i]
                  name' = T.format "User #{}" [i]
                  email' = T.format "u{}@hat.hat" [i]
              uid' <- randomShortUid
              now  <- getCurrentTime
              encPass <- encryptPassIO' (Pass (T.encodeUtf8 nick'))
              u <- Acid.update db $
                AddUser uid' nick' name' encPass email' now
              when (i < 20) $ Acid.update db $
                SetAdmin uid' True
              when (i `mod` 10 == 0) $
                putStr "."
              return u
            putStrLn ""
            -- generating games
            putStrLn "Generating games g{0..9} with n×10 players in each"
            for_ [0..9::Int] $ \i -> do
              let title' = T.format "Game-{}" [i]
                  wordReq' = Just (WordReq mempty 10)
              players' <- S.fromList . map (view uid) . take (i*10) <$>
                            shuffleM generatedUsers
              delay <- (60 *) <$> getRandomR (0, 120::Int)
              registerUntil' <- addUTCTime (fromIntegral delay) <$>
                                  getCurrentTime
              uid' <- randomShortUid
              createdBy' <- view uid <$> uniform generatedUsers
              Acid.update db $
                AddGame uid' title' createdBy' wordReq' registerUntil' players'
              putStr "."
            putStrLn ""
        )

      addCommand "room.reschedule"
        "Generate a new schedule for a room"
        (\(gameId, roomNum) -> reschedule db gameId roomNum)
        ((,) <$> gameArg
             <*> argument auto (metavar "ROOM"))
