module WebToInk.Converter (main, prepareKindleGeneration) where

import System.Directory (createDirectoryIfMissing, setCurrentDirectory)
import System.Environment (getArgs)
import System.IO (writeFile)
import Data.List.Utils (replace)
import Data.List (isPrefixOf, nub)

import WebToInk.Converter.HtmlPages 
import WebToInk.Converter.Images (getImages)
import WebToInk.Converter.Download (downloadPage, savePage, downloadAndSaveImages, getSrcFilePath)
import WebToInk.Converter.OpfGeneration (generateOpf)
import WebToInk.Converter.TocGeneration (generateToc)
import WebToInk.Converter.CommandLineParser (Args(..), legend, parseArgs)
import WebToInk.Converter.Types
import WebToInk.Converter.Constants

main :: IO ()
main = do   

    args <- (fmap parseArgs) getArgs 

    case argsTocUrl args of
        Just tocUrl -> prepareKindleGeneration 
                            (argsTitle args)     
                            (argsAuthor args)   
                            (argsLanguage args) 
                            (tocUrl) 
                            (argsFolder args)
                       >> return ()
        Nothing     -> putStrLn legend
                          

prepareKindleGeneration :: Maybe String -> Maybe String -> String -> Url -> FilePath -> IO FilePath 
prepareKindleGeneration maybeTitle maybeAuthor language tocUrl folder = do

    maybeGetHtmlPagesResult <- getHtmlPages tocUrl

    case maybeGetHtmlPagesResult of
        Just result   -> prepare result 
        Nothing       -> putStrLn "Error could not download table of contents and processed no html pages!!!"
                         >> return ""
  where 
        prepare (GetHtmlPagesResult tocContent pagesDic) = do
            let author = resolveAuthor maybeAuthor tocContent
            let title = resolveTitle maybeTitle tocContent

            let topPagesDic = filter (isTopLink . fst) pagesDic
            let topPages = map fst topPagesDic

            putStrLn $ prettifyList topPagesDic
            
            createKindleStructure title author topPagesDic topPages

          where 
            createKindleStructure title author topPagesDic topPages = do
                let targetFolder = folder ++ "/" ++ title
                 
                createDirectoryIfMissing False targetFolder  
                setCurrentDirectory targetFolder

                result <- downloadPages tocUrl topPagesDic    
                
                let failedFileNames = map piFileName $ failedPages result
                let goodTopPages = filter (`notElem` failedFileNames) topPages

                putStrLn "\nDownload Summary"
                putStrLn   "----------------\n"

                putStr "Successfully downloaded:"
                putStrLn $ (prettifyList goodTopPages) ++ "\n"

                putStr "Failed to download:"
                putStrLn $ (prettifyList failedFileNames) ++"\n"

                putStrLn "Generating book.opf"
                let opfString = generateOpf goodTopPages (allImageUrls result) title language author 
                writeFile "book.opf" opfString

                putStrLn "Generating toc.ncx"
                let tocString = generateToc goodTopPages title language author
                writeFile "toc.ncx" tocString

                setCurrentDirectory ".."
                
                return targetFolder
                    

downloadPages :: Url -> [(FilePath, Url)] -> IO DownloadPagesResult 
downloadPages tocUrl topPagesDic = do
    let rootUrl = getRootUrl tocUrl

    downloadResults <- mapM (\(fileName, pageUrl) ->
        tryProcessPage $ PageInfo rootUrl pageUrl fileName) topPagesDic 
    
    let uniqueImageUrls = 
            map (getSrcFilePath "") . nub . concat . map allImageUrls $ downloadResults 
    let allFailedPages = concat . map failedPages $ downloadResults
    return $ DownloadPagesResult uniqueImageUrls allFailedPages

tryProcessPage :: PageInfo -> IO (DownloadPagesResult)
tryProcessPage pi = do
    maybePageContents <- downloadPage (piPageUrl pi)

    case maybePageContents of
        Just pageContents -> do
            imageUrls <- processPage pi pageContents 
            return $ DownloadPagesResult imageUrls []
        Nothing           -> return $ DownloadPagesResult [] [pi]
        
processPage :: PageInfo -> PageContents -> IO [String]
processPage pi pageContents = do
    let imageUrls = (filter (not . ("https:" `isPrefixOf`)) . getImages) pageContents

    downloadAndSaveImages (piRootUrl pi) (piPageUrl pi) imageUrls

    let adaptedPageContents = cleanAndLocalize imageUrls pageContents

    savePage (piFileName pi) adaptedPageContents

    return imageUrls

cleanAndLocalize :: [Url] -> PageContents -> PageContents
cleanAndLocalize imageUrls pageContents = 
    removeScripts . removeBaseHref .  localizeSrcUrls ("../" ++ imagesFolder) imageUrls $ pageContents 

prettifyList :: Show a => [a] -> String
prettifyList = foldr ((++) . (++) "\n" . show) ""

