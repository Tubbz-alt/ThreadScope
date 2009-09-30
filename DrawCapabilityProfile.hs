module DrawCapabilityProfile (withViewScale, currentView) where

-- Imports for GTK/Glade
import Graphics.Rendering.Cairo 
import qualified Graphics.Rendering.Cairo as C
import Graphics.UI.Gtk

-- Imports for GHC Events
import qualified GHC.RTS.Events as GHCEvents
import GHC.RTS.Events hiding (Event)

-- Haskell library imports
import Data.List
import qualified Data.Function

import Control.Monad

import Text.Printf
import Debug.Trace

-- ThreadScope imports
import State
import CairoDrawing
import EventlogViewerCommon
import Ticks
import ViewerColours

-------------------------------------------------------------------------------

withViewScale :: ViewParameters -> Render () -> Render ()
withViewScale params@ViewParameters{..} inner = do
   save
   translate (-hadjValue/scaleValue) 0
   scale (1/scaleValue) 1.0
   inner
   restore

-------------------------------------------------------------------------------
-- This function draws the current view of all the HECs with Cario

currentView :: ViewParameters -> Rectangle -> HECs -> Render ()
currentView params@ViewParameters{..} (Rectangle rx ry rw rh) hecs
  = do   
         let lastTx :: Timestamp
             lastTx = findLastTxValue hecs

             scale_rx    = fromIntegral rx * scaleValue
             scale_rw    = fromIntegral rw * scaleValue
             scale_width = fromIntegral width * scaleValue

             startPos :: Timestamp
             startPos = fromIntegral (max 0 (truncate (scale_rx + hadjValue)))
                        -- hadj_value might be negative, as we leave a
                        -- small gap before the trace starts at the beginning

             endPos :: Timestamp
             endPos = ceiling (hadjValue + scale_width)
                        `min` ceiling (hadjValue + scale_rx + scale_rw)
                        `min` lastTx

         trace (printf "rx = %d, scale_rx = %f, scale_rw = %f, hadjValue = %f, startPos = %d, endPos = %d" rx scale_rx scale_rw hadjValue startPos endPos) $ do

         selectFontFace "times" FontSlantNormal FontWeightNormal
         setFontSize 12
         setSourceRGBAhex blue 1.0
         setLineWidth 1.0
         withViewScale params $ do
         -- trace (printf "startPos: %d, endPos: %d" startPos endPos) $ do
         draw_line (startPos, oy) (endPos, oy)
         let 
             timestampFor100Pixels = truncate (100 * scaleValue) -- ns time for 100 pixels
             snappedTickDuration :: Timestamp
             snappedTickDuration = 10 ^ truncate (logBase 10 (fromIntegral timestampFor100Pixels) :: Double)
             tickWidthInPixels :: Int
             tickWidthInPixels = truncate ((fromIntegral snappedTickDuration) / scaleValue)
             firstTick :: Timestamp
             firstTick = snappedTickDuration * (startPos `div` snappedTickDuration)
         --liftIO $
         --  do putStrLn ("timestampFor100Pixels = " ++ show timestampFor100Pixels)
         --     putStrLn ("tickWidthInPixels     = " ++ show tickWidthInPixels)
         --     putStrLn ("snappedTickDuration   = " ++ show snappedTickDuration)       
         drawTicks tickWidthInPixels height scaleValue firstTick snappedTickDuration  (10*snappedTickDuration) endPos

         sequence_ [ hecView c params startPos endPos eventTree
                   | (c, eventTree) <- hecs]

-------------------------------------------------------------------------------
-- hecView draws the trace for a single HEC

hecView :: Int -> ViewParameters -> 
           Timestamp -> Timestamp -> EventTree -> Render ()

hecView !c params@ViewParameters{..} !startPos !endPos
        (EventSplit s splitTime e _ _ nrEvents runAv gcAv) 
        | startPos < splitTime && endPos >= splitTime && 
	  (fromIntegral (e - s) / scaleValue) <= fromIntegral detail &&
          nrEvents > 2
  = -- View spans both left and right sub-tree.
    -- trace (printf "hecView (average): start:%d end:%d s:%d e:%d" startPos endPos s e) $
    drawAverageDuration c params s e runAv gcAv

hecView c params@ViewParameters{..} startPos endPos
       (EventSplit _ splitTime _ lhs rhs _ _ _)
  = -- trace (printf "hecView: start:%d end:%d s:%d e:%d" startPos endPos s e) $
    do when (startPos < splitTime) $
         hecView c params startPos endPos lhs
       when (endPos >= splitTime) $
         hecView c params startPos endPos rhs

hecView c  params@ViewParameters{..} startPos endPos
       (EventTreeLeaf eventList)
  = mapM_ (drawDuration c params) eventsInView
    where
    eventsInView = [e | e <- eventList, inView startPos endPos e]

-------------------------------------------------------------------------------
-- An event is in view if it is not outside the view.

inView :: Timestamp -> Timestamp -> EventDuration -> Bool
inView viewStart viewEnd event
  = not (eStart > viewEnd || eEnd <= viewStart)
  where
    eStart = timeOfEventDuration event
    eEnd   = endTimeOfEventDuration event

-------------------------------------------------------------------------------

drawAverageDuration :: Int -> ViewParameters
		    -> Timestamp -> Timestamp -> Timestamp -> Timestamp
		    -> Render ()
drawAverageDuration c ViewParameters{..} startTime endTime _runAv gcAv
  = do setSourceRGBAhex (if not bwMode then runningColour else black) 1.0
       draw_outlined_rectangle startTime              -- x
                      (oycap+c*gapcap)                -- y
                      (endTime - startTime)           -- w
                       barHeight
       setSourceRGBAhex black 1.0
       --move_to (oxs + startTime, oycap+c*gapcap)
       --relMoveTo (4/scaleValue) 13
       --unscaledText scaleValue (show nrEvents)
       setSourceRGBAhex (if not bwMode then gcColour else black) gcRatio
       draw_rectangle startTime                       -- x
                      (oycap+c*gapcap+barHeight)      -- y
                      (endTime - startTime)           -- w
                      (barHeight `div` 2)             -- h

    where
    duration = endTime - startTime
--    runRatio :: Double
--    runRatio = (fromIntegral runAv) / (fromIntegral duration)
    gcRatio :: Double
    gcRatio = (fromIntegral gcAv) / (fromIntegral duration)

-------------------------------------------------------------------------------

unscaledText :: Double -> String -> Render ()
unscaledText _scaleValue text
  = do m <- getMatrix
       identityMatrix
       textPath text
       C.fill        
       setMatrix m

-------------------------------------------------------------------------------

textWidth :: Double -> String -> Render TextExtents
textWidth _scaleValue text
  = do m <- getMatrix
       identityMatrix
       tExtent <- textExtents text
       setMatrix m
       return tExtent

-------------------------------------------------------------------------------
-- For this scale value (and higher) display discrete events.

detailThreshold :: Double
detailThreshold = 3000

-------------------------------------------------------------------------------

drawDuration :: Int -> ViewParameters -> EventDuration -> Render ()

drawDuration c ViewParameters{..}
                (ThreadRun t s startTime endTime)
  = do setSourceRGBAhex (if not bwMode then runningColour else black) 0.8
       setLineWidth (1/scaleValue)
       draw_rectangle_opt False
                      startTime                  -- x
                      (oycap+c*gapcap)           -- y
                      (endTime - startTime)      -- w
                       barHeight                 -- h
       -- Optionally label the bar with the threadID if there is room
       tExtent <- textWidth scaleValue tStr
       when (textExtentsWidth tExtent + 6 < fromIntegral rectWidth)
         $ do move_to (startTime, oycap+c*gapcap) 
              setSourceRGBAhex labelTextColour 1.0
              relMoveTo (4/scaleValue) 13
              unscaledText scaleValue tStr
        -- Optionally write the reason for the thread being stopped
        -- depending on the zoom value
       when False
         $ do setSourceRGBAhex black 1.0
              move_to (endTime, oycap+c*gapcap+barHeight+12)
              unscaledText scaleValue (show t ++ " " ++ showThreadStopStatus s)
    where
    rectWidth = truncate (fromIntegral (endTime - startTime) / scaleValue) -- as pixels
    tStr = show t


drawDuration c ViewParameters{..} (GC startTime endTime)
  = do setSourceRGBAhex (if not bwMode then gcColour else black) 1.0
       draw_rectangle_opt False
                      startTime                      -- x
                      (oycap+c*gapcap+barHeight)     -- y
                      (endTime - startTime)          -- w
                      (barHeight `div` 2)            -- h

drawDuration c ViewParameters{..} (EV event)
  = case spec event of 
      CreateThread{thread=t} -> 
        when (scaleValue <= detailThreshold) $ do
          setSourceRGBAhex lightBlue 1.0 
          setLineWidth (3 * scaleValue)
          draw_line (time event, oycap+c*gapcap-4) (time event, oycap+c*gapcap+barHeight+4)
          when (True && labelsMode)
            (do setSourceRGB 0 0.0 0.0
                move_to (time event, oycap+c*gapcap+barHeight+12)
                unscaledText scaleValue (show t ++ " created")
            )
      RunThread{}  -> return ()
      StopThread{} -> return ()
      RunSpark{} -> 
           when (scaleValue <= detailThreshold) $
             do setSourceRGBAhex magenta 0.8 
                setLineWidth (3/scaleValue)
                draw_line (time event, oycap+c*gapcap-4)
                          (time event, oycap+c*gapcap+barHeight+4)
      ThreadRunnable{thread=t} ->
        when (scaleValue <= detailThreshold) $ do
           setSourceRGBAhex darkGreen 0.8 
           setLineWidth (3*scaleValue)
           draw_line (time event, oycap+c*gapcap-4)
                     (time event, oycap+c*gapcap+barHeight+4)
           when (scaleValue < 200 && not labelsMode)
            (do setSourceRGB 0.0 0.0 0.0
                move_to (eScale event scaleValue, oycap+c*gapcap-5)
                unscaledText scaleValue (show t ++ " runnable")
            )
      RequestSeqGC{} -> 
        when (scaleValue <= detailThreshold) $ do
           setSourceRGBAhex cyan 0.8 
           setLineWidth (3*scaleValue)
           draw_line (time event, oycap+c*gapcap-4)
                     (time event, oycap+c*gapcap+barHeight+4)
           when (scaleValue >= subscriptThreashold && not labelsMode)
            (do setSourceRGB 0 0.0 0.0
                move_to (time event, oycap+c*gapcap-5)
                unscaledText scaleValue ("seq GC req")
            )
      RequestParGC{} -> 
         when (scaleValue <= detailThreshold) $ do
           setSourceRGBA 1.0 0.0 1.0 0.8 
           setLineWidth (3*scaleValue)
           draw_line (time event, oycap+c*gapcap-4)
                     (time event, oycap+c*gapcap+barHeight+4)
           when (labelsMode)
            (do setSourceRGB 0 0.0 0.0
                move_to (time event, oycap+c*gapcap-5)
                unscaledText scaleValue ("par GC req")
            )
      StartGC -> return ()
      MigrateThread {thread=t, newCap=newc}
        -> when (scaleValue <= detailThreshold) $ do
              setSourceRGBAhex darkRed 0.8 
              setLineWidth (3*scaleValue)
              draw_line (time event, oycap+newc*gapcap-4)
                        (time event, oycap+newc*gapcap+barHeight+4)
              when (labelsMode)
               (do setSourceRGB 0.0 0.0 0.0
                   move_to (time event, oycap+newc*gapcap+barHeight+12)
                   unscaledText scaleValue (show t ++ " migrated from " ++ show c)
               )
      WakeupThread {thread=t, otherCap=otherc}
        -> when (scaleValue <= detailThreshold) $ do 
              setSourceRGBAhex purple 0.8 
              setLineWidth (3*scaleValue)
              draw_line (time event, oycap+c*gapcap-4)
                        (time event, oycap+c*gapcap+barHeight+4)
              when (labelsMode)
               (do setSourceRGB 0.0 0.0 0.0
                   move_to (time event, oycap+c*gapcap+barHeight+12)
                   unscaledText scaleValue (show t ++ " woken from " ++ show otherc)
               )
      Shutdown{} ->
         do setSourceRGBAhex shutdownColour 0.8
            draw_rectangle (time event) (oycap+c*gapcap) (truncate (fromIntegral barHeight * scaleValue) :: Int) barHeight
      _ -> return () 

-------------------------------------------------------------------------------

eScale :: GHCEvents.Event -> Double -> Int
eScale event scaleValue = truncate (fromIntegral (time event))

-------------------------------------------------------------------------------

subscriptThreashold :: Double
subscriptThreashold = 1000000  

-------------------------------------------------------------------------------
