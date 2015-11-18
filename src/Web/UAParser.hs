{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE TemplateHaskell           #-}

module Web.UAParser
    ( -- * Parsing browser (user agent)
      parseUA
    , UAResult (..)
    , uarVersion

      -- * Parsing OS
    , parseOS
    , OSResult (..)
    , osrVersion

      -- * Parsing Dev
    , parseDev
    , parseDevLenient
    , DevResult (..)
    ) where

-------------------------------------------------------------------------------
import           Control.Applicative
import           Control.Monad
import           Data.Aeson
import           Data.ByteString.Char8 (ByteString)
import           Data.Default
import           Data.FileEmbed
import           Data.Generics
import           Data.Maybe
import           Data.Monoid
import           Data.Text             (Text)
import qualified Data.Text             as T
import qualified Data.Text.Encoding    as T
import           Data.Yaml
import           Text.Regex.PCRE.Light
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
-- UA Parser
-------------------------------------------------------------------------------
uaConfig :: UAConfig
uaConfig = either error id $ decodeEither $(embedFile "deps/uap-core/regexes.yaml")
{-# NOINLINE uaConfig #-}


-------------------------------------------------------------------------------
-- | Parse a given User-Agent string
parseUA :: ByteString -> Maybe UAResult
parseUA bs = msum $ map go uaParsers
    where
      UAConfig{..} = uaConfig

      go UAParser{..} = either (const Nothing) mkRes
                      . mapM T.decodeUtf8' =<< match uaRegex bs []
        where
          mkRes [_,f,v1,v2,v3] = Just $ UAResult (repF f) (repV1 v1) (repV2 v2) (repV3 v3)
          mkRes [_,f,v1,v2]    = Just $ UAResult (repF f) (repV1 v1) (repV2 v2) uaV3Rep
          mkRes [_,f,v1]       = Just $ UAResult (repF f) (repV1 v1) uaV2Rep uaV3Rep
          mkRes [_,f]          = Just $ UAResult (repF f) uaV1Rep uaV2Rep uaV3Rep
          mkRes _              = Nothing

          repV1 x = uaV1Rep `mplus` Just x
          repV2 x = uaV2Rep `mplus` Just x
          repV3 x = uaV3Rep `mplus` Just x
          repF x = maybe x id uaFamRep



-------------------------------------------------------------------------------
-- | Results datatype for the parsed User-Agent
data UAResult = UAResult {
      uarFamily :: Text
    , uarV1     :: Maybe Text
    , uarV2     :: Maybe Text
    , uarV3     :: Maybe Text
    } deriving (Show, Read, Eq, Typeable, Data)


-------------------------------------------------------------------------------
-- | Construct a browser version-string from 'UAResult'
uarVersion :: UAResult -> Text
uarVersion UAResult{..} =
    T.intercalate "." . catMaybes . takeWhile isJust $ [uarV1, uarV2, uarV3]


-------------------------------------------------------------------------------
instance Default UAResult where
    def = UAResult "" Nothing Nothing Nothing


-------------------------------------------------------------------------------
-- OS Parser
-------------------------------------------------------------------------------


-- | Parse OS from given User-Agent string
parseOS :: ByteString -> Maybe OSResult
parseOS "" = Just def
parseOS bs = msum $ map go osParsers
    where
      UAConfig{..} = uaConfig

      go OSParser{..} = either (const Nothing) mkRes
                      . mapM T.decodeUtf8' =<< match osRegex bs []
          where
          mkRes [_,f,v1,v2,v3,v4] = Just $ OSResult (repF f) (repV1 v1) (repV2 v2) (repV3 v3) (repV4 v4)
          mkRes [_,f,v1,v2,v3]    = Just $ OSResult (repF f) (repV1 v1) (repV2 v2) (repV3 v3) osRep4
          mkRes [_,f,v1,v2]       = Just $ OSResult (repF f) (repV1 v1) (repV2 v2) osRep3 osRep4
          mkRes [_,f,v1]          = Just $ OSResult (repF f) (repV1 v1) osRep2 osRep3 osRep4
          mkRes [_,f]             = Just $ OSResult (repF f) osRep1 osRep2 osRep3 osRep4
          mkRes _                 = Nothing

          repF x = maybe x id osFamRep

          repV1 x = osRep1 `mplus` Just x
          repV2 x = osRep2 `mplus` Just x
          repV3 x = osRep3 `mplus` Just x
          repV4 x = osRep4 `mplus` Just x


-------------------------------------------------------------------------------
-- | Result type for 'parseOS'
data OSResult = OSResult {
      osrFamily :: Text
    , osrV1     :: Maybe Text
    , osrV2     :: Maybe Text
    , osrV3     :: Maybe Text
    , osrV4     :: Maybe Text
    } deriving (Show,Read,Eq,Typeable,Data)

instance Default OSResult where
    def = OSResult "Other" Nothing Nothing Nothing Nothing


-------------------------------------------------------------------------------
-- | Construct a version string from 'OSResult'
osrVersion :: OSResult -> Text
osrVersion OSResult{..} =
    T.intercalate "." . catMaybes . takeWhile isJust $ [osrV1, osrV2, osrV3, osrV4]


-------------------------------------------------------------------------------
-- Dev Parser
-------------------------------------------------------------------------------
-- | Parser that, upon failure to match a pattern returns a result of
-- family "Other" with all other fields blank. This is mainly for
-- compatibility with the uap-core test suite
parseDevLenient :: ByteString -> DevResult
parseDevLenient = fromMaybe def . parseDev


parseDev :: ByteString -> Maybe DevResult
parseDev bs = msum $ map go devParsers
    where
      UAConfig{..} = uaConfig

      go DevParser{..} = either (const Nothing) mkRes
                       . mapM T.decodeUtf8' =<< match devRegex bs []
        where
          mkRes caps@(_:f:b:m:_) = Just $ mkDR (repF caps f) (repBrand caps (Just b)) (repModel caps (Just m))
          mkRes caps@[_,f,b]   = Just $ mkDR (repF caps f) (repBrand caps (Just b)) (repModel caps Nothing)
          mkRes caps@[_,f]     = Just $ mkDR (repF caps f) (repBrand caps Nothing) (repModel caps Nothing)
          mkRes caps@[f]       = Just $ mkDR (repF caps f) (repBrand caps Nothing) (repModel caps Nothing)
          mkRes _         = Nothing

          mkDR a b c = DevResult (T.strip a) (strip' =<< b) (strip' =<< c)

          strip' t  = case T.strip t of
                        "" -> Nothing
                        t' -> Just t'

          --TODO: update other replacers to be like this if it works
          --TODO: some patterns don't capture so you should match on [f]
          repBrand caps x = maybe x Just (makeReplacements caps <$> devBrandRep)
          -- This technique is used in the python ua-parser. It isn't
          -- clear if there's a precedent in the spec but it clears up
          -- some remote edge cases (which may be test suite bugs TBH).
          repModel caps x = maybe (x <|> firstCap) Just (makeReplacements caps <$> devModelRep)
            where firstCap = case caps of
                               _:a:_ -> Just a
                               _     -> Nothing

          --TODO: tryrep this
          repF caps x = maybe x (makeReplacements caps) devFamRep


-------------------------------------------------------------------------------
-- | Replace replacement placeholders with captures and remove any
-- that are unused. Goes up to $4 as per the spec
makeReplacements
    :: [Text]
    -- ^ Captures
    -> Text
    -- ^ Replacement text with 1-indexed replace points ($1, $2, $3 or $4)
    -> Text
makeReplacements (_:cs) t = makeReplacements' (zip ([1..4] :: [Int]) (cs ++ repeat "")) t
  where makeReplacements' [] acc = acc
        makeReplacements' ((idx, cap):caps) acc = let acc' = T.replace ("$" <> showT idx) cap acc
                                        in makeReplacements' caps acc'
makeReplacements _ t = t


-------------------------------------------------------------------------------
showT :: Show a => a -> Text
showT = T.pack . show


-------------------------------------------------------------------------------
-- | Result type for 'parseDev'
data DevResult = DevResult {
      drFamily :: Text
    , drBrand  :: Maybe Text
    , drModel  :: Maybe Text
    } deriving (Show,Read,Eq,Typeable,Data)


instance Default DevResult where
    def = DevResult "Other" Nothing Nothing


-------------------------------------------------------------------------------
-- Parser Config
-------------------------------------------------------------------------------

-- | User-Agent string parser data
data UAConfig = UAConfig {
      uaParsers  :: [UAParser]
    , osParsers  :: [OSParser]
    , devParsers :: [DevParser]
    } deriving (Eq,Show)


-------------------------------------------------------------------------------
data UAParser = UAParser {
      uaRegex  :: Regex
    , uaFamRep :: Maybe Text
    , uaV1Rep  :: Maybe Text
    , uaV2Rep  :: Maybe Text
    , uaV3Rep  :: Maybe Text
    } deriving (Eq,Show)


-------------------------------------------------------------------------------
data OSParser = OSParser {
      osRegex  :: Regex
    , osFamRep :: Maybe Text
    , osRep1   :: Maybe Text
    , osRep2   :: Maybe Text
    , osRep3   :: Maybe Text
    , osRep4   :: Maybe Text
    } deriving (Eq,Show)


-------------------------------------------------------------------------------
data DevParser = DevParser {
      devRegex    :: Regex
    , devFamRep   :: Maybe Text
    , devBrandRep :: Maybe Text
    , devModelRep :: Maybe Text
    } deriving (Eq,Show)


-------------------------------------------------------------------------------
parseRegex :: Object -> Parser Regex
parseRegex v = do
  pat <- v .: "regex"
  flag <- v .:? "regex_flag" :: Parser (Maybe Text)
  let flags = case flag of
                Just "i" -> [caseless]
                _        -> []
  return (compile (T.encodeUtf8 pat) flags)


-------------------------------------------------------------------------------
instance FromJSON UAConfig where
    parseJSON (Object v) =
      UAConfig
        <$> v .: "user_agent_parsers"
        <*> v .: "os_parsers"
        <*> v .: "device_parsers"
    parseJSON _ = error "Object expected when parsing JSON"


-------------------------------------------------------------------------------
instance FromJSON UAParser where
    parseJSON (Object v) =
      UAParser <$> parseRegex v
               <*> v .:? "family_replacement"
               <*> v .:? "v1_replacement"
               <*> v .:? "v2_replacement"
               <*> v .:? "v3_replacement"
    parseJSON _ = error "Object expected when parsing JSON"


-------------------------------------------------------------------------------
instance FromJSON OSParser where
    parseJSON (Object v) =
      OSParser <$> parseRegex v
               <*> v .:? "os_replacement"
               <*> v .:? "os_v1_replacement"
               <*> v .:? "os_v2_replacement"
               <*> v .:? "os_v3_replacement"
               <*> v .:? "os_v4_replacement"
    parseJSON _ = error "Object expected when parsing JSON"


-------------------------------------------------------------------------------
instance FromJSON DevParser where
    parseJSON (Object v) = do
      r <- parseRegex v
      fam <- v .:? "device_replacement"
      brandRep <- v .:? "brand_replacement"
      modRep <- v .:? "model_replacement"
      return (DevParser { devRegex    = r
                        , devFamRep    = fam
                        , devBrandRep = brandRep
                        , devModelRep = modRep})
    parseJSON _ = error "Object expected when parsing JSON"
