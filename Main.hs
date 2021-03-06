{-#LANGUAGE OverloadedStrings#-}

module Main (
              main
            ) where

import           BookLibrary
import           Control.Applicative ((<$>))
import qualified Data.ByteString.Lazy as B (readFile, writeFile, append)
import qualified Data.ByteString.Lazy.Char8 as B8 (unpack)
import           Data.Csv hiding (lookup)
import qualified Data.Vector as V (Vector, toList, length, filter)
import           Encrypt
import           System.Directory (renameFile)
import           System.Environment (getArgs)
import           System.IO (openTempFile, hClose)
import           System.Process (runCommand)
import           Tools
import           Types

main :: IO ()
main = getArgs >>= go
    where go []                       = putStrLn $ "Wrong number of arguments.\n" ++ usage -- no argument : what do to ?
          go ("--help":_)             = putStrLn usage
          go ("-h":_)                 = go ["--help"]
          go ("--list":_)             = list
          go ("-l":_)                 = go ["--list"]
          go ("--init":_)             = withLibrary (initiate Nothing)
          go ("-i":_)                 = go ["--init"]
          go ("--reset":_)            = reset Nothing
          go ("-r":_)                 = go ["--reset"]
          go ("--add":service:user:_) = add service user
          go ("-a":service:user:_)    = go ["--add", service, user]
          go ("--delete":service:_)   = delete service
          go ("-d":service:_)         = go ["--delete", service]
          go ("--extract":service:_)  = extract service
          go ("-e":service:_)         = go ["--extract", service]
          go _                        = putStrLn $ "Error in arguments.\n" ++ usage

-- Prompt the user for a new master password and create his associated entry book
initiate :: Maybe String -> FilePath -> IO ()
initiate Nothing libFile = do
  putStrLn $ "You are going to create a new, empty entry book, are you sure you want to continue ? (yes/no)"
  answer <- getLine
  initiate (Just answer) libFile
initiate (Just "no") _ = putStrLn "Initialization aborded, library book left untouched."
initiate (Just "yes") libFile = do
  -- Ask user for his master pwd, check that it doesn't already exist and generate a random filename for it
  masterPwd <- askMasterPwd
  pwdExist <- libraryLookup masterPwd
  case pwdExist of
    Just _ -> putStrLn "There already exists a library file associated with that master password.\n\
                       \Consider re-using or chose another master password."
    Nothing -> do
      (filename, h) <- hpmFolder >>= flip openTempFile "bookEntry"
      hClose h
      let libEntry = encode [LibraryEntry masterPwd filename]
      oldDecrypted <- B.readFile libFile >>= return . decrypt
      let newDecrypted = oldDecrypted `B.append` libEntry
      newEncrypted <- encrypt newDecrypted
      (tempName, tempH) <- hpmFolder >>= flip openTempFile ".tempLibrary"
      hClose tempH
      B.writeFile tempName newEncrypted
      renameFile tempName libFile
      putStrLn "New library book initiated. You can start storing passwords now."
  
initiate _ libFile = putStrLn "Answer with \"yes\" or \"no\"." >> initiate Nothing libFile

-- Lookup generalized for the library book to be used with 'withLibrary'
libraryLookup :: PwdHash -> IO (Maybe FilePath)
libraryLookup pwd = withLibrary $ \libFile -> do
                      libraryRaw <- B.readFile libFile >>= return . decrypt
                      let libraryDec = decode NoHeader libraryRaw :: Either String (V.Vector LibraryEntry)
                      case libraryDec of
                        Left _ -> error $ "Error while trying to read the library, file may be corrupted\n"
                        Right library -> return $ entryLookup pwd (V.toList library)

-- Lookup generalized for the entry book.
bookLookup :: FilePath -> Service -> IO (Maybe Pwd)
bookLookup book serv = do
  entries <- decode NoHeader <$> (B.readFile book >>= return . decrypt)
  case entries of
    Left _ -> error parsingProblem
    Right entries' -> return $ bookLookup' serv (V.toList entries')

bookLookup' :: Service -> [PasswordEntry] -> Maybe Pwd
bookLookup' _ [] = Nothing
bookLookup' serv (x:xs) = if serv == getService x then
                              Just (getPwd x)
                          else
                              bookLookup' serv xs

-- lookup like function that applies to LibraryEntry data type
entryLookup :: PwdHash -> [LibraryEntry] -> Maybe FilePath
entryLookup _ [] = Nothing
entryLookup pwdHash (x:xs) = if (getLibraryHash x) == pwdHash then
                                 Just (getLibraryFile x)
                             else
                                 entryLookup pwdHash xs

-- Prompt for master password and delete all stored passwords in an entry book
reset :: Maybe String -> IO ()
reset Nothing = do
  putStrLn "You are about to delete all stored passwords in your entry book, are you sure ?(yes/no)"
  answer <- getLine
  reset (Just answer)
reset (Just "no") = putStrLn "Reset aborded, entry book left untouched."
reset (Just "yes") = do
  masterPwd <- askMasterPwd
  bookEntry <- libraryLookup masterPwd
  go bookEntry
      where go Nothing          = putStrLn noEntryBook
            go (Just entryBook) = do 
                                   encrypt "" >>= B.writeFile entryBook -- write empty string in file to erase its contents
                                   putStrLn "Entry book was erased successfully.\n"
reset _ = putStrLn "Please answer with \"yes\" or \"no\".\n" >> reset Nothing

-- Prompt for master password and store the new entry in the associated entry book
add :: Service -> User -> IO ()
add [] _ = putStrLn $ "Error in arguments.\n" ++ usage
add _ [] = add [] [] -- calls above
add service user =
    askPassword (Just "Type your MASTER password to access your entry book.\n") >>= libraryLookup >>= go
        where go Nothing = putStrLn noEntryBook
              go (Just entryBook) = do
                -- Check that there is not already a password entry for that service
                exists <- withBook entryBook (flip bookLookup service)
                case exists of
                  Just _  -> putStrLn $ "There already exists a password entry for service \"" ++ service ++ "\" in your book."
                  Nothing -> do
                              pwd <- askPassword (Just $ "Type the password you want to associate to service \"" ++ service ++ "\" and user \"" ++ user ++ "\": ")
                              let newEntry = encode [PasswordEntry service user pwd]
                              oldDecrypted <- B.readFile entryBook >>= return . decrypt
                              newEncrypted <- encrypt $ oldDecrypted `B.append` newEntry
                              (tempName, tempH) <- hpmFolder >>= flip openTempFile "tempEntryBook"
                              hClose tempH
                              B.writeFile tempName newEncrypted
                              renameFile tempName entryBook
                              putStrLn "New password entry added to entry book."
                

-- List password entries from an entry book
list :: IO ()
list = do
  exists <- askMasterPwd >>= libraryLookup
  case exists of
    Nothing        -> putStrLn noEntryBook
    Just entryBook -> do
                entries <- (decode NoHeader <$> (B.readFile entryBook >>= return . decrypt)) :: IO (Either String (V.Vector PasswordEntry))
                case entries of
                  Left _         -> putStrLn parsingProblem
                  Right entries' -> putStrLn ("\nShowing (" ++ show (V.length entries') ++ ") entries :")
                                    >> mapM_ (putStrLn . ("  > " ++) . show) (V.toList entries')

-- Deletes a password entry associated to the service
delete :: Service -> IO ()
delete service = do
  exists <- askMasterPwd >>= libraryLookup
  case exists of
    Nothing        -> putStrLn noEntryBook
    Just entryBook -> do
                entries <- (decode NoHeader <$> (B.readFile entryBook >>= return . decrypt)) :: IO (Either String (V.Vector PasswordEntry))
                case entries of
                  Left _         -> putStrLn parsingProblem
                  Right entries' -> do
                               let newEntries = flip V.filter entries' (\e -> service /= getService e)
                               encrypt (encode $ V.toList newEntries) >>= B.writeFile entryBook
                               putStrLn "Password entry removed if it existed.\n"

-- Extracts a password associated to the service

extract :: Service -> IO ()
extract service = do
  exists <- askMasterPwd >>= libraryLookup
  case exists of
    Nothing        -> putStrLn noEntryBook
    Just entryBook -> do
                entries <- (decode NoHeader <$> (B.readFile entryBook >>= return . decrypt)) :: IO (Either String (V.Vector PasswordEntry))
                case entries of
                  Left _         -> putStrLn parsingProblem
                  Right _ -> do
                               pass <- bookLookup entryBook service
                               case pass of
                                 Nothing    -> putStrLn $ "No password entry for service \"" ++ service ++ "\" found in your entry book."
                                 Just pass' -> do
                                           let passStr = B8.unpack pass'
                                           runCommand ("echo " ++ passStr ++ " | xclip -i") >> putStrLn "Password now in clipboard."
