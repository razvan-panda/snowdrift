{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | Subsite for email-and-passphrase authentication.
module AuthSite (module AuthSiteTypes, module AuthSite) where

import Prelude

import Control.Error
import Control.Lens
import Control.Monad
import Crypto.Nonce (Generator, nonce128urlT)
import Crypto.PasswordStore
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text.Encoding
import Data.Time
import Data.Typeable
import Database.Persist.Sql
import Yesod
import qualified Crypto.Nonce as Nonce
import qualified Data.Text as T

-- Used to create a single, applicationd-wide nonce token. I'm doing this
-- out of expediency; Yesod.Auth uses it and nobody seems to care. But I
-- don't like it.
-- https://github.com/yesodweb/yesod/issues/1245
import System.IO.Unsafe (unsafePerformIO)

import AuthSiteTypes

-- Need this until we switch back to using messages instead of
-- Yesod-specific "alerts".
import Alerts

-- Still need this until we take the time to put ''type AuthUser'' into the
-- AuthMaster class
import Model
type AuthUser = Entity User

-- | Any site that uses this subsite needs to instantiate this class.
class AuthMaster y where

    -- | Where to go after logout and login
    postLoginRoute :: y -> Route y
    postLogoutRoute :: y -> Route y

    -- | What to show on the login page. This page should have a form that posts
    -- 'Credentials' to 'LoginR'. See 'AuthHarness' in the tests for a
    -- simplistic example.
    loginHandler :: HandlerT y IO TypedContent

    -- | What to show on the create-account page. This page should post
    -- 'Credentials' to 'CreateAccountR'.
    createAccountHandler :: HandlerT y IO TypedContent

    -- | What to show on the reset-passphrase page. This page should post
    -- 'Credentials' to 'ResetPassphraseR'
    resetPassphraseHandler :: HandlerT y IO TypedContent

    -- | What to show on the verify-account page. This page should post
    -- 'Text' (the token) to 'VerifyAccountR'
    verifyAccountHandler :: HandlerT y IO TypedContent

    -- | This module sends emails, in case that wasn't obvious.
    -- "Network.Mail.Mime" or "Network.Mail.Mime.SES" have good options for
    -- this method.
    sendAuthEmail :: AuthEmail -> AuthMailMessage -> HandlerT y IO ()

-- | A token used to confirm an email address.
newtype Token = Token { fromToken :: Text } deriving Show

-- | The type of message you are expected to send.
data AuthMailMessage
        = VerifyUserCreation Token
        | VerifyPassReset Token
        | BadUserCreation
        -- ^ Sent when user tried to use an existing email address
        | BadPassReset
        -- ^ Sent when user tried to use a *nonexistent* email address
        deriving Show

-- ** Internal types.

newtype AuthEmail = AuthEmail { fromAuth :: Text } deriving Show

newtype ClearPassphrase = ClearPassphrase { fromClear :: Text } deriving Show

newtype PassphraseDigest = PassphraseDigest ByteString deriving Show

data Credentials = Credentials
        { loginAuth :: AuthEmail
        , loginPass :: ClearPassphrase
        } deriving (Show)

data VerifiedUser = VerifiedUser
        { verifiedEmail :: Text
        , verifiedDigest :: ByteString
        }

data Verification = Verification
        { verifyEmail :: AuthEmail
        , verifyToken :: Token
        } deriving Show

-- | Used with Yesod caching feature
newtype CachedAuth a = CachedAuth { unCachedAuth :: Maybe a } deriving Typeable

-- ** Invoke Yesod TH to make the subsite.

instance (Yesod master
         ,YesodPersist master
         ,YesodPersistBackend master ~ SqlBackend
         ,RenderMessage master FormMessage
         ,AuthMaster master)
        => YesodSubDispatch AuthSite (HandlerT master IO) where
    yesodSubDispatch = $(mkYesodSubDispatch resourcesAuthSite)

-- ** Duplicating Yesod.Auth API for a wee while.

maybeAuth :: (YesodPersist m
             ,YesodPersistBackend m ~ SqlBackend)
          => HandlerT m IO (Maybe AuthUser)
maybeAuth = runMaybeT $ do
    k <- MaybeT $ lookupSession authSessionKey
    uid <- MaybeT $ pure (fromPathPiece k)
    u <- MaybeT $ fmap unCachedAuth (cached (runDB $ fmap CachedAuth (get uid)))
    pure (Entity uid u)

requireAuth :: (Yesod m
               ,YesodPersist m
               ,YesodPersistBackend m ~ SqlBackend)
            => HandlerT m IO AuthUser
requireAuth = maybe noAuth pure =<< maybeAuth
  where
    noAuth = do
        setUltDestCurrent
        maybe notAuthenticated redirect . authRoute =<< getYesod

-- | A decent default form for 'Credentials', to be considered part of the
-- external API.
credentialsForm :: (RenderMessage (HandlerSite m) FormMessage, MonadHandler m)
          => AForm m Credentials
credentialsForm = Credentials
    <$> (AuthEmail <$> areq textField "Email"{fsAttrs=emailAttrs}  Nothing)
    <*> (ClearPassphrase <$> areq passwordField "Passphrase" Nothing)
  where
    emailAttrs = [("autofocus",""), ("autocomplete","email")]

-- ** Functions and operations for doing auth. To be considered internal.

authSessionKey :: Text
authSessionKey = "_AUTHID"

-- Per the docs, this number should increase by 1 every two years, starting
-- at 17 in 2014. Thus, 17 + (now^.year - 2014) / 2. We could even TH that
-- bizniss.
--
-- Ok, I TH'd it. Will I regret it? Yes. Leaving it commented for
-- now.
pbkdf1Strength :: Int
pbkdf1Strength = 18
-- pbkdf1Strength = 17 + (yr - 2014) `div` 2
--   where yr = $(litE =<< runIO (fmap ( IntegerL
--                                     . (\(a,_,_) -> a)
--                                     . toGregorian
--                                     . utctDay)
--                                     getCurrentTime))

-- | Yesod.Auth uses this, and it's apparently ok.
-- https://github.com/yesodweb/yesod/issues/1245
tokenGenerator :: Generator
tokenGenerator = unsafePerformIO Nonce.new
{-# NOINLINE tokenGenerator #-}

-- | Our wrap over makePassword
makeAuthPass t = makePassword (encodeUtf8 t) pbkdf1Strength

-- | Compare some Credentials to what's stored in the database.
checkCredentials :: MonadIO m => Credentials -> SqlPersistT m (Maybe AuthUser)
checkCredentials Credentials{..} = do
    mu <- getBy (UniqueUsr (fromAuth loginAuth))
    pure $ verify =<< mu
  where
    verify x@(Entity uid u) =
        if verifyPassword (encodeUtf8 (fromClear loginPass)) (u^.userDigest)
            then Just x
            else Nothing

-- | Verify a token given by the user. This is *destructive*; a token can
-- only ever be checked once.
checkToken :: MonadIO m => Token -> SqlPersistT m (Maybe ProvisionalUser)
checkToken (Token t) = runMaybeT $ do
    Entity pid p@ProvisionalUser{..} <- MaybeT $ getBy (UniqueTok t)
    _ <- justM (delete pid)
    now <- justM (liftIO getCurrentTime)
    if addUTCTime twoHours puCreationTime > now
        then just p
        else nothing
  where
    twoHours = 2 * 60 * 60
    justM = MaybeT . fmap Just

-- | Create a provisional user
provisional :: Credentials -> Verification -> IO ProvisionalUser
provisional Credentials{..} Verification{..} =
    ProvisionalUser <$> email <*> passDigest <*> token <*> curtime
  where
    email = pure (fromAuth loginAuth)
    passDigest = makeAuthPass (fromClear loginPass)
    token = pure (fromToken verifyToken)
    curtime = getCurrentTime

genVerificationToken :: Credentials -> IO Verification
genVerificationToken Credentials{..} =
    Verification loginAuth . Token <$> nonce128urlT tokenGenerator

-- | This privileged function must be used with care.
privilegedCreateUser :: MonadIO m => VerifiedUser -> SqlPersistT m ()
privilegedCreateUser VerifiedUser{..} =
    insert_ (User verifiedEmail verifiedDigest)

-- | This privileged function must be used with care. It modifies the
-- user's session; it's the difference between being logged in and not!
priviligedLogin :: Yesod master => AuthUser -> HandlerT master IO ()
priviligedLogin = setSession authSessionKey . toPathPiece . entityKey

-- | Store a provisional user for later verification. Returns the token to
-- use for verification.
priviligedProvisionalUser :: MonadIO m
                          => Credentials -> SqlPersistT m Verification
priviligedProvisionalUser creds = do
    verf <- liftIO (genVerificationToken creds)
    prov <- liftIO (provisional creds verf)
    _ <- upsertOn (UniqueProvUsr (puEmail prov)) prov []
    pure verf
  where
    upsertOn uniqueKey record updates = do
        mExists <- getBy uniqueKey
        k <- case mExists of
            Just (Entity k _) -> do
              when (null updates) (replace k record)
              return k
            Nothing           -> insert record
        Entity k `liftM` updateGet k updates

-- | Log out by deleting the session var
logout :: Yesod master => HandlerT master IO ()
logout = deleteSession authSessionKey

getLoginR :: (Yesod m, RenderMessage m FormMessage, AuthMaster m)
          => HandlerT AuthSite (HandlerT m IO) TypedContent
getLoginR = lift $ loginHandler

postLoginR :: (Yesod master
              ,AuthMaster master
              ,YesodPersist master
              ,YesodPersistBackend master ~ SqlBackend
              ,RenderMessage master FormMessage)
           => HandlerT AuthSite (HandlerT master IO) Html
postLoginR = do
    ((res', _), _) <- lift $ runFormPost (renderDivs credentialsForm)
    p <- getRouteToParent
    formResult (lift . (runAuthResult p <=< (runDB . checkCredentials)))
               res'
  where
    runAuthResult parent = maybe
        (do
            alertDanger [shamlet|Bad credentials:  <a href="https://tree.taiga.io/project/snowdrift/us/392">See Taiga #392</a>.|]
            redirect (parent LoginR))
        (\u -> do
            priviligedLogin u
            alertInfo "Welcome"
            redirect =<< (postLoginRoute <$> getYesod))

formResult success = \case
    FormSuccess x -> success x
    FormFailure msgs -> failure msgs
    FormMissing -> failure ["No login data"]
  where
    failure msgs =
        lift $ defaultLayout [whamlet|
            <p>Auth form failures are not handled yet.
            <p>TBD: <a href="https://tree.taiga.io/project/snowdrift/us/392">See Taiga #392</a>.
            <p>Errors: #{show msgs}
            |]

-- ** Logout page

getLogoutR :: (Yesod master
              ,AuthMaster master)
            => HandlerT AuthSite (HandlerT master IO) Html
getLogoutR = lift $ do
    logout
    alertInfo "You are now logged out."
    redirect =<< (postLogoutRoute <$> getYesod)

-- ** CreateAccount page

getCreateAccountR :: (Yesod m, RenderMessage m FormMessage, AuthMaster m)
                  => HandlerT AuthSite (HandlerT m IO) TypedContent
getCreateAccountR = lift $ createAccountHandler

postCreateAccountR :: (Yesod master
                      ,AuthMaster master
                      ,YesodPersistBackend master ~ SqlBackend
                      ,YesodPersist master
                      ,RenderMessage master FormMessage)
                   => HandlerT AuthSite (HandlerT master IO) Html
postCreateAccountR = do
    ((res, _), _) <- lift $ runFormPost (renderDivs credentialsForm)
    flip formResult res (\c@Credentials{..} -> do
        mu <- lift (runDB (getBy (UniqueUsr (fromAuth loginAuth))))
        lift $ sendAuthEmail loginAuth =<< maybe
            (VerifyUserCreation . verifyToken
                <$> runDB (priviligedProvisionalUser c))
            (pure . const BadUserCreation)
            mu
        redirectParent VerifyAccountR
        )

-- | ResetPassphrase page
getResetPassphraseR :: (Yesod m, RenderMessage m FormMessage, AuthMaster m)
                     => HandlerT AuthSite (HandlerT m IO) TypedContent
getResetPassphraseR = lift $ resetPassphraseHandler

postResetPassphraseR :: (Yesod master
                        ,AuthMaster master
                        ,YesodPersistBackend master ~ SqlBackend
                        ,YesodPersist master
                        ,RenderMessage master FormMessage)
                     => HandlerT AuthSite (HandlerT master IO) Html
postResetPassphraseR = do
    ((res, _), _) <- lift $ runFormPost (renderDivs credentialsForm)
    flip formResult res (\c@Credentials{..} -> do
        mu <- lift (runDB (getBy (UniqueUsr (fromAuth loginAuth))))
        lift $ sendAuthEmail loginAuth =<< maybe
            (pure BadUserCreation)
            (const $ VerifyPassReset . verifyToken
                <$> runDB (priviligedProvisionalUser c))
            mu
        redirectParent VerifyAccountR
        )

-- | VerifyAccount page
getVerifyAccountR :: (Yesod m, RenderMessage m FormMessage, AuthMaster m)
                  => HandlerT AuthSite (HandlerT m IO) TypedContent
getVerifyAccountR = lift $ verifyAccountHandler

-- | Handle an attempted verification.
--
-- Steps taken:
-- 1a get the form data
-- 2a get/delete the provisional user
-- 3a ensure that it isn't expired
-- 4a upsert the user
--
-- Potential problems:
-- 1b -> formfailure (using formResult)
-- 2b -> indicates the token was already used or something. Show a page
-- with options to log in, get saved password? Or just redirect to
-- Login page which has all of those options. Ok, do that with a
-- warning
-- 3b -> Same deal as 2b
-- 4b -> this should not ever fail ;) If it does? Redirect anyway? Makes me
-- think, what happens if storing the provisional user fails? Eh, internal
-- error page. Good enough.
--
-- This method is rather blithe in the belief that the priviliged methods
-- above ensure that a good token is truly "good".
postVerifyAccountR :: (Yesod m
                      ,YesodPersist m
                      ,YesodPersistBackend m ~ SqlBackend
                      ,RenderMessage m FormMessage)
                   => HandlerT AuthSite (HandlerT m IO) Html
postVerifyAccountR = do
    ((res, _), _) <-
        lift $ runFormPost (renderDivs (Token <$> areq textField "" Nothing))
    -- 1a
    flip formResult res $ \tok -> do
        -- 2a/3a
        -- Have to check the token and insert the user in the same
        -- transaction, lest race conditions boggle the contraptions
        mm <- lift $ runDB $ sequence . fmap upsertUser =<< checkToken tok
        case mm of
            Nothing -> do
                lift $ alertWarning "Uh oh, your token appears to be invalid!"
                redirectParent LoginR
            Just _ -> do
                lift $ alertSuccess "You are all set! Log in to continue."
                redirectParent LoginR
  where
    upsertUser :: MonadIO m => ProvisionalUser -> SqlPersistT m (Entity User)
    upsertUser ProvisionalUser{..} = do
        upsert (User puEmail puDigest)
               [UserDigest =. puDigest]

redirectParent r = do
    p <- getRouteToParent
    lift (redirect (p r))
