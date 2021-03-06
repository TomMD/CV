{-#LANGUAGE ForeignFunctionInterface, ViewPatterns,ParallelListComp, FlexibleInstances, FlexibleContexts, TypeFamilies, EmptyDataDecls, ScopedTypeVariables, StandaloneDeriving, DeriveDataTypeable, UndecidableInstances, MultiParamTypeClasses #-}
#include "cvWrapLEO.h"
module CV.Image (
-- * Basic types
 Image(..)
, MutableImage(..)
, Mask
, create
, createWith
, empty
, toMutable
, fromMutable
, emptyCopy
, emptyCopy'
, cloneImage
, withClone
, withMask
, withMutableClone
, withCloneValue
, CreateImage
, Save(..)

-- * Colour spaces
, ChannelOf
, GrayScale
, Complex
, BGR
, RGB
, RGBA
, RGB_Channel(..)
, LAB
, LAB_Channel(..)
, D32
, D64
, D8
, Tag
, lab
, rgba
, rgb
, compose
, composeMultichannelImage

-- * IO operations
, Loadable(..)
, saveImage
, loadColorImage
, loadImage

-- * Pixel level access
, GetPixel(..)
, SetPixel(..)
, safeGetPixel
, getAllPixels
, getAllPixelsRowMajor
, mapImageInplace

-- * Image information
, ImageDepth
, Sized(..)
, biggerThan
, getArea
, getChannel
, getImageChannels
, getImageDepth
, getImageInfo

-- * ROI's, COI's and subregions
, setCOI
, setROI
, resetROI
, getRegion
, withIOROI
--, withROI

-- * Blitting
, blendBlit
, blit
, blitM
, subPixelBlit
, safeBlit
, montage
, tileImages

-- * Conversions
, convertTo
, rgbToGray
, rgbToGray8
, grayToRGB
, rgbToLab
, bgrToRgb
, rgbToBgr
, cloneTo64F
, unsafeImageTo32F 
, unsafeImageTo64F 
, unsafeImageTo8Bit 

-- * Low level access operations
, BareImage(..)
, creatingImage
, unImage
, unS
, withGenBareImage
, withBareImage
, creatingBareImage
, withGenImage
, withImage
, withMutableImage
, withRawImageData
, imageFPTR
, ensure32F

-- * Extended error handling
, setCatch
, CvException
, CvSizeError(..)
, CvIOError(..)
) where

import System.Mem
import System.Directory
import System.FilePath

import Foreign.C.Types
import Foreign.C.String
import Foreign.Marshal.Utils
import Foreign.ForeignPtr hiding (newForeignPtr,unsafeForeignPtrToPtr)
import Foreign.Concurrent
import Foreign.Ptr
import Control.Parallel.Strategies
import Control.DeepSeq
import Control.Lens

import CV.Bindings.Error

import Data.Maybe(catMaybes)
import Data.List(genericLength)
import Foreign.Marshal.Array
import Foreign.Marshal.Alloc
import Foreign.Ptr
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import Foreign.Storable
import System.IO.Unsafe
import Data.Word
import qualified Data.Complex as C
import Control.Monad
import Control.Exception
import Data.Data
import Data.Typeable

import Utils.GeometryClass
import Control.Applicative hiding (empty)




-- Colorspaces

-- | Single channel grayscale image
data GrayScale
data Complex
data RGB
data RGB_Channel = Red | Green | Blue deriving (Eq,Ord,Enum)

data BGR

data LAB
data YUV
data RGBA
data LAB_Channel = LAB_L | LAB_A | LAB_B deriving (Eq,Ord,Enum)
data YUV_Channel = YUV_Y | YUV_U | YUV_V deriving (Eq,Ord,Enum)

-- | Type family for expressing which channels a colorspace contains. This needs to be fixed wrt. the BGR color space.
type family ChannelOf a :: *
type instance ChannelOf RGB_Channel = RGB
type instance ChannelOf LAB_Channel = LAB
type instance ChannelOf YUV_Channel = YUV

-- Bit Depths
type D8  = Word8
type D32 = Float
type D64 = Double

-- | The type for Images
newtype Image channels depth = S BareImage
newtype MutableImage channels depth = Mutable (Image channels depth)

-- | Alias for images used as masks
type Mask = Maybe (Image GrayScale D8)

-- | Remove typing info from an image
unS (S i) = i -- Unsafe and ugly

imageFPTR :: Image c d -> ForeignPtr BareImage
imageFPTR (S (BareImage fptr)) = fptr

withImage :: Image c d -> (Ptr BareImage ->IO a) -> IO a
withImage (S i) op = withBareImage i op
--withGenNewImage (S i) op = withGenImage i op

withRawImageData :: Image c d -> (Int -> Ptr Word8 -> IO a) -> IO a
withRawImageData (S i) op = withBareImage i $ \pp-> do
                             d  <- {#get IplImage->imageData#} pp 
                             wd <- {#get IplImage->widthStep#} pp
                             op (fromIntegral wd) (castPtr d)

-- Ok. this is just the example why I need image types
withUniPtr with x fun = with x $ \y ->
                    fun (castPtr y)

withGenImage :: Image c d -> (Ptr b -> IO a) -> IO a
withGenImage = withUniPtr withImage

-- | This function converts masks to pointers. Masks which are nothing are converted
--   to null pointers.
withMask :: Mask -> (Ptr b -> IO a) -> IO a
withMask (Just i) op = withUniPtr withImage i op
withMask Nothing  op = op nullPtr

withMutableImage :: MutableImage c d -> (Ptr b -> IO a) -> IO a
withMutableImage (Mutable i) o = withGenImage i o

withGenBareImage :: BareImage -> (Ptr b -> IO a) -> IO a
withGenBareImage = withUniPtr withBareImage

{#pointer *IplImage as BareImage foreign newtype#}

freeBareImage ptr = with ptr {#call cvReleaseImage#}

--foreign import ccall "& wrapReleaseImage" releaseImage :: FinalizerPtr BareImage

instance NFData (Image a b) where
    rnf a@(S (BareImage fptr)) = (unsafeForeignPtrToPtr) fptr `seq` a `seq` ()-- This might also need peek?


creatingImage fun = do
              iptr <- fun
--              {#call incrImageC#} -- Uncomment this line to get statistics of number of images allocated by ghc
              fptr <- newForeignPtr iptr (freeBareImage iptr)
              return . S . BareImage $ fptr

creatingBareImage fun = do
              iptr <- fun
--              {#call incrImageC#} -- Uncomment this line to get statistics of number of images allocated by ghc
              fptr <- newForeignPtr iptr (freeBareImage iptr)
              return . BareImage $ fptr

unImage (S (BareImage fptr)) = fptr

data Tag tp;
rgb = undefined :: Tag RGB
rgba = undefined :: Tag RGBA
lab = undefined :: Tag LAB

-- | Typeclass for elements that are build from component elements. For example,
--   RGB images can be constructed from three grayscale images.
class Composes a where
   type Source a :: *
   compose :: Source a -> a

instance (CreateImage (Image RGBA a)) => Composes (Image RGBA a) where
   type Source (Image RGBA a) = (Image GrayScale a, Image GrayScale a
                               ,Image GrayScale a, Image GrayScale a)
   compose (r,g,b,a) = composeMultichannelImage (Just b) (Just g) (Just r) (Just a) rgba

instance (CreateImage (Image RGB a)) => Composes (Image RGB a) where
   type Source (Image RGB a) = (Image GrayScale a, Image GrayScale a, Image GrayScale a)
   compose (r,g,b) = composeMultichannelImage (Just b) (Just g) (Just r) Nothing rgb

instance (CreateImage (Image LAB a)) => Composes (Image LAB a) where
   type Source (Image LAB a) = (Image GrayScale a, Image GrayScale a, Image GrayScale a)
   compose (l,a,b) = composeMultichannelImage (Just l) (Just a) (Just b) Nothing lab

{-# DEPRECATED composeMultichannelImage "This is unsafe. Use compose instead" #-}
composeMultichannelImage :: (CreateImage (Image tp a)) => Maybe (Image GrayScale a) -> Maybe (Image GrayScale a) -> Maybe (Image GrayScale a) -> Maybe (Image GrayScale a) -> Tag tp -> Image tp a
composeMultichannelImage = composeMultichannel

composeMultichannel :: (CreateImage (Image tp a)) => Maybe (Image GrayScale a) -> Maybe (Image GrayScale a) -> Maybe (Image GrayScale a) -> Maybe (Image GrayScale a) -> Tag tp -> Image tp a
composeMultichannel (c2)
                         (c1)
                         (c3)
                         (c4)
                         totag
    = unsafePerformIO $ do
        res <- create (size) -- TODO: Check channel count -- This is NOT correct
        withMaybe c1 $ \cc1 ->
         withMaybe c2 $ \cc2 ->
          withMaybe c3 $ \cc3 ->
           withMaybe c4 $ \cc4 ->
            withGenImage res $ \cres -> {#call cvMerge#} cc1 cc2 cc3 cc4 cres
        return res
    where
        withMaybe (Just i) op = withGenImage i op
        withMaybe (Nothing) op = op nullPtr
        size = getSize . head . catMaybes $ [c1,c2,c3,c4]


-- | Typeclass for CV items that can be read from file. Mainly images at this point.
class Loadable a where
    readFromFile :: FilePath -> IO a


instance Loadable ((Image GrayScale D32)) where
    readFromFile fp = do
        e <- loadImage fp
        case e of
         Just i -> return i
         Nothing -> throw $ CvIOError $ "Could not load "++fp

instance Loadable ((Image RGB D32)) where
    readFromFile fp = do
        e <- loadColorImage8 fp
        case e of
         Just i -> return $ unsafeImageTo32F $ bgrToRgb i
         Nothing -> throw $ CvIOError $ "Could not load "++fp

instance Loadable ((Image RGB D8)) where
    readFromFile fp = do
        e <- loadColorImage8 fp
        case e of
         Just i -> return $ bgrToRgb i
         Nothing -> throw $ CvIOError $ "Could not load "++fp

instance Loadable ((Image GrayScale D8)) where
    readFromFile fp = do
        e <- loadImage8 fp
        case e of
         Just i -> return i
         Nothing -> throw $ CvIOError $ "Could not load "++fp


-- | This function loads and converts image to an arbitrary format. Notice that it is
--   polymorphic enough to cause run time errors if the declared and actual types of the
--   images do not match. Use with care.
unsafeloadUsing x p n = do
              exists <- doesFileExist n
              if not exists then return Nothing
                            else do
                              i <- withCString n $ \name ->
                                     creatingBareImage ({#call cvLoadImage #} name p)
                              bw <- x i
                              return . Just . S $ bw

loadImage :: FilePath -> IO (Maybe (Image GrayScale D32))
loadImage = unsafeloadUsing imageTo32F 0
loadImage8 :: FilePath -> IO (Maybe (Image GrayScale D8))
loadImage8 = unsafeloadUsing imageTo8Bit 0
loadColorImage :: FilePath -> IO (Maybe (Image BGR D32))
loadColorImage = unsafeloadUsing imageTo32F 1
loadColorImage8 :: FilePath -> IO (Maybe (Image BGR D8))
loadColorImage8 = unsafeloadUsing imageTo8Bit 1


instance Sized (MutableImage a b) where
    type Size (MutableImage a b) = IO (Int,Int)
   -- getSize :: (Integral a, Integral b) => Image c d -> (a,b)
    getSize (Mutable i) = evaluate (deep (getSize i))
      where
        deep a = a `deepseq` a

instance Sized BareImage where
    type Size BareImage = (Int,Int)
   -- getSize :: (Integral a, Integral b) => Image c d -> (a,b)
    getSize image = unsafePerformIO $ withBareImage image $ \i -> do
                 w <- {#call getImageWidth#} i
                 h <- {#call getImageHeight#} i
                 return (fromIntegral w,fromIntegral h)

instance Sized (Image c d) where
    type Size (Image c d) = (Int,Int)
    getSize = getSize . unS


#c
enum CvtFlags {
    CvtFlip   = CV_CVTIMG_FLIP,
    CvtSwapRB = CV_CVTIMG_SWAP_RB
     };
#endc

#c
enum CvtCodes {
    BGR2BGRA    =0,
    RGB2RGBA    =BGR2BGRA,

    BGRA2BGR    =1,
    RGBA2RGB    =BGRA2BGR,

    BGR2RGBA    =2,
    RGB2BGRA    =BGR2RGBA,

    RGBA2BGR    =3,
    BGRA2RGB    =RGBA2BGR,

    BGR2RGB     =4,
    RGB2BGR     =BGR2RGB,

    BGRA2RGBA   =5,
    RGBA2BGRA   =BGRA2RGBA,

    BGR2GRAY    =6,
    RGB2GRAY    =7,
    GRAY2BGR    =8,
    GRAY2RGB    =GRAY2BGR,
    GRAY2BGRA   =9,
    GRAY2RGBA   =GRAY2BGRA,
    BGRA2GRAY   =10,
    RGBA2GRAY   =11,

    BGR2BGR565  =12,
    RGB2BGR565  =13,
    BGR5652BGR  =14,
    BGR5652RGB  =15,
    BGRA2BGR565 =16,
    RGBA2BGR565 =17,
    BGR5652BGRA =18,
    BGR5652RGBA =19,

    GRAY2BGR565 =20,
    BGR5652GRAY =21,

    BGR2BGR555  =22,
    RGB2BGR555  =23,
    BGR5552BGR  =24,
    BGR5552RGB  =25,
    BGRA2BGR555 =26,
    RGBA2BGR555 =27,
    BGR5552BGRA =28,
    BGR5552RGBA =29,

    GRAY2BGR555 =30,
    BGR5552GRAY =31,

    BGR2XYZ     =32,
    RGB2XYZ     =33,
    XYZ2BGR     =34,
    XYZ2RGB     =35,

    BGR2YCrCb   =36,
    RGB2YCrCb   =37,
    YCrCb2BGR   =38,
    YCrCb2RGB   =39,

    BGR2HSV     =40,
    RGB2HSV     =41,

    BGR2Lab     =44,
    RGB2Lab     =45,

    BayerBG2BGR =46,
    BayerGB2BGR =47,
    BayerRG2BGR =48,
    BayerGR2BGR =49,

    BayerBG2RGB =BayerRG2BGR,
    BayerGB2RGB =BayerGR2BGR,
    BayerRG2RGB =BayerBG2BGR,
    BayerGR2RGB =BayerGB2BGR,

    BGR2Luv     =50,
    RGB2Luv     =51,
    BGR2HLS     =52,
    RGB2HLS     =53,

    HSV2BGR     =54,
    HSV2RGB     =55,

    Lab2BGR     =56,
    Lab2RGB     =57,
    Luv2BGR     =58,
    Luv2RGB     =59,
    HLS2BGR     =60,
    HLS2RGB     =61,

    BayerBG2BGR_VNG =62,
    BayerGB2BGR_VNG =63,
    BayerRG2BGR_VNG =64,
    BayerGR2BGR_VNG =65,

    BayerBG2RGB_VNG =BayerRG2BGR_VNG,
    BayerGB2RGB_VNG =BayerGR2BGR_VNG,
    BayerRG2RGB_VNG =BayerBG2BGR_VNG,
    BayerGR2RGB_VNG =BayerGB2BGR_VNG,

    BGR2HSV_FULL = 66,
    RGB2HSV_FULL = 67,
    BGR2HLS_FULL = 68,
    RGB2HLS_FULL = 69,

    HSV2BGR_FULL = 70,
    HSV2RGB_FULL = 71,
    HLS2BGR_FULL = 72,
    HLS2RGB_FULL = 73,

    LBGR2Lab     = 74,
    LRGB2Lab     = 75,
    LBGR2Luv     = 76,
    LRGB2Luv     = 77,

    Lab2LBGR     = 78,
    Lab2LRGB     = 79,
    Luv2LBGR     = 80,
    Luv2LRGB     = 81,

    BGR2YUV      = 82,
    RGB2YUV      = 83,
    YUV2BGR      = 84,
    YUV2RGB      = 85,

    COLORCVT_MAX  =100
};
#endc

{#enum CvtCodes {}#}

{#enum CvtFlags {}#}

rgbToLab :: Image RGB D32 -> Image LAB D32
rgbToLab = S . convertTo RGB2Lab 3 . unS

rgbToYUV :: Image RGB D32 -> Image YUV D32
rgbToYUV = S . convertTo RGB2YUV 3 . unS

rgbToGray :: Image RGB D32 -> Image GrayScale D32
rgbToGray = S . convertTo RGB2GRAY 1 . unS

rgbToGray8 :: Image RGB D8 -> Image GrayScale D8
rgbToGray8 = S . convert8UTo RGB2GRAY 1 . unS

grayToRGB :: Image GrayScale D32 -> Image RGB D32
grayToRGB = S . convertTo GRAY2BGR 3 . unS

bgrToRgb :: Image BGR D8 -> Image RGB D8
bgrToRgb = S . swapRB . unS

rgbToBgr :: Image RGB D8 -> Image BGR D8
rgbToBgr = S . swapRB . unS

swapRB :: BareImage -> BareImage
swapRB img = unsafePerformIO $ do
    res <- cloneBareImage img
    withBareImage img $ \cimg ->
     withBareImage res $ \cres ->
        {#call cvConvertImage#} (castPtr cimg) (castPtr cres) (fromIntegral . fromEnum $ CvtSwapRB)
    return res


safeGetPixel :: (Sized image, Size image ~ (Int,Int), GetPixel image) => (P image) -> (Int,Int) -> image -> P image
safeGetPixel def (x,y) i | x<0 || x>= w || y<0 || y>=h = def
                     | otherwise = getPixel (x,y) i
                where
                    (w,h) = getSize i
                    -- (x',y') = (clamp (0,w-1) x, clamp (0,h-1) y)

clamp :: Ord a => (a, a) -> a -> a
clamp (a,b) x = max a (min b x)

instance (NFData (P (Image a b)), GetPixel (Image a b)) => GetPixel (MutableImage a b) where
    type P (MutableImage a b) = IO (P (Image a b))
    getPixel xy (Mutable i) = let p = getPixel xy i
                              in p `deepseq` return p

class GetPixel a where
    type P a :: *
    getPixel   :: (Int,Int) -> a -> P a

-- #define FGET(img,x,y) (((float *)((img)->imageData + (y)*(img)->widthStep))[(x)])
instance GetPixel (Image GrayScale D32) where
    type P (Image GrayScale D32) = D32
    {-#INLINE getPixel#-}
    getPixel (x,y) i = unsafePerformIO $
                        withGenImage i $ \c_i -> do
                                         d <- {#get IplImage->imageData#} c_i
                                         s <- {#get IplImage->widthStep#} c_i
                                         peek (castPtr (d`plusPtr` (y*(fromIntegral s) +x*sizeOf (0::Float))):: Ptr Float)

instance GetPixel (Image GrayScale D8) where
    type P (Image GrayScale D8) = D8
    {-#INLINE getPixel#-}
    getPixel (x,y) i = unsafePerformIO $
                        withGenImage i $ \c_i -> do
                                         d <- {#get IplImage->imageData#} c_i
                                         s <- {#get IplImage->widthStep#} c_i
                                         peek (castPtr (d`plusPtr` (y*(fromIntegral s) +x*sizeOf (0::Word8))):: Ptr Word8)

instance GetPixel (Image Complex D32) where
    type P (Image Complex D32) = C.Complex D32
    {-#INLINE getPixel#-}
    getPixel (x,y) i = unsafePerformIO $
                        withGenImage i $ \c_i -> do
                                         d <- {#get IplImage->imageData#} c_i
                                         s <- {#get IplImage->widthStep#} c_i
                                         let cs = fromIntegral s
                                             fs = sizeOf (undefined :: Float)
                                         re <- peek (castPtr (d`plusPtr` (y*cs + x*2*fs)))
                                         im <- peek (castPtr (d`plusPtr` (y*cs +(x*2+1)*fs)))
                                         return (re C.:+ im)

-- #define UGETC(img,color,x,y) (((uint8_t *)((img)->imageData + (y)*(img)->widthStep))[(x)*3+(color)])
instance GetPixel (Image RGB D32) where
    type P (Image RGB D32) = (D32,D32,D32)
    {-#INLINE getPixel#-}
    getPixel (x,y) i = unsafePerformIO $
                        withGenImage i $ \c_i -> do
                                         d <- {#get IplImage->imageData#} c_i
                                         s <- {#get IplImage->widthStep#} c_i
                                         let cs = fromIntegral s
                                             fs = sizeOf (undefined :: Float)
                                         b <- peek (castPtr (d`plusPtr` (y*cs +x*3*fs)))
                                         g <- peek (castPtr (d`plusPtr` (y*cs +(x*3+1)*fs)))
                                         r <- peek (castPtr (d`plusPtr` (y*cs +(x*3+2)*fs)))
                                         return (r,g,b)
instance GetPixel (Image BGR D32) where
    type P (Image BGR D32) = (D32,D32,D32)
    {-#INLINE getPixel#-}
    getPixel (x,y) i = unsafePerformIO $
                        withGenImage i $ \c_i -> do
                                         d <- {#get IplImage->imageData#} c_i
                                         s <- {#get IplImage->widthStep#} c_i
                                         let cs = fromIntegral s
                                             fs = sizeOf (undefined :: Float)
                                         b <- peek (castPtr (d`plusPtr` (y*cs +x*3*fs)))
                                         g <- peek (castPtr (d`plusPtr` (y*cs +(x*3+1)*fs)))
                                         r <- peek (castPtr (d`plusPtr` (y*cs +(x*3+2)*fs)))
                                         return (r,g,b)
instance  GetPixel (Image BGR D8) where
    type P (Image BGR D8) = (D8,D8,D8)
    {-#INLINE getPixel#-}
    getPixel (x,y) i = unsafePerformIO $
                        withGenImage i $ \c_i -> do
                                         d <- {#get IplImage->imageData#} c_i
                                         s <- {#get IplImage->widthStep#} c_i
                                         let cs = fromIntegral s
                                             fs = sizeOf (undefined :: D8)
                                         b <- peek (castPtr (d`plusPtr` (y*cs +x*3*fs)))
                                         g <- peek (castPtr (d`plusPtr` (y*cs +(x*3+1)*fs)))
                                         r <- peek (castPtr (d`plusPtr` (y*cs +(x*3+2)*fs)))
                                         return (r,g,b)

instance  GetPixel (Image RGB D8) where
    type P (Image RGB D8) = (D8,D8,D8)
    {-#INLINE getPixel#-}
    getPixel (x,y) i = unsafePerformIO $
                        withGenImage i $ \c_i -> do
                                         d <- {#get IplImage->imageData#} c_i
                                         s <- {#get IplImage->widthStep#} c_i
                                         let cs = fromIntegral s
                                             fs = sizeOf (undefined :: D8)
                                         b <- peek (castPtr (d`plusPtr` (y*cs +x*3*fs)))
                                         g <- peek (castPtr (d`plusPtr` (y*cs +(x*3+1)*fs)))
                                         r <- peek (castPtr (d`plusPtr` (y*cs +(x*3+2)*fs)))
                                         return (r,g,b)

instance GetPixel (Image LAB D32) where
    type P (Image LAB D32) = (D32,D32,D32)
    {-#INLINE getPixel#-}
    getPixel (x,y) i = unsafePerformIO $
                        withGenImage i $ \c_i -> do
                                         d <- {#get IplImage->imageData#} c_i
                                         s <- {#get IplImage->widthStep#} c_i
                                         let cs = fromIntegral s
                                             fs = sizeOf (undefined :: Float)
                                         l <- peek (castPtr (d`plusPtr` (y*cs +x*3*fs)))
                                         a <- peek (castPtr (d`plusPtr` (y*cs +(x*3+1)*fs)))
                                         b <- peek (castPtr (d`plusPtr` (y*cs +(x*3+2)*fs)))
                                         return (l,a,b)

-- | Perform (a destructive) inplace map of the image. This should be wrapped inside
-- withClone or an image operation
mapImageInplace :: (P (Image GrayScale D32) -> P (Image GrayScale D32))
            -> MutableImage GrayScale D32
            -> IO ()
mapImageInplace f image = withMutableImage image $ \c_i -> do
             d <- {#get IplImage->imageData#} c_i
             s <- {#get IplImage->widthStep#} c_i
             (w,h) <- getSize image
             let cs = fromIntegral s
                 fs = sizeOf (undefined :: Float)
             forM_ [(x,y) | x<-[0..w-1], y <- [0..h-1]] $ \(x,y) -> do
                   v <- peek (castPtr (d `plusPtr` (y*cs+x*fs)))
                   poke (castPtr (d `plusPtr` (y*cs+x*fs))) (f v)



convert8UTo :: CvtCodes -> CInt -> BareImage -> BareImage
convert8UTo code channels img = unsafePerformIO $ creatingBareImage $ do
    res <- {#call wrapCreateImage8U#} w h channels
    withBareImage img $ \cimg ->
        {#call cvCvtColor#} (castPtr cimg) (castPtr res) (fromIntegral . fromEnum $ code)
    return res
 where
    (fromIntegral -> w,fromIntegral -> h) = getSize img

convertTo :: CvtCodes -> CInt -> BareImage -> BareImage
convertTo code channels img = unsafePerformIO $ creatingBareImage $ do
    res <- {#call wrapCreateImage32F#} w h channels
    withBareImage img $ \cimg ->
        {#call cvCvtColor#} (castPtr cimg) (castPtr res) (fromIntegral . fromEnum $ code)
    return res
 where
    (fromIntegral -> w,fromIntegral -> h) = getSize img

-- | Class for images that exist.
class CreateImage a where
    -- | Create an image from size
    create :: (Int,Int) -> IO a

createWith :: CreateImage (Image c d) => (Int,Int) -> (MutableImage c d -> IO (MutableImage c d)) -> IO (Image c d)
createWith s f = do
    c <- create s
    Mutable r <- f (Mutable c)
    return r




instance CreateImage (Image GrayScale D32) where
    create (w,h) = creatingImage $ {#call wrapCreateImage32F#} (fromIntegral w) (fromIntegral h) 1
instance CreateImage (Image Complex D32) where
    create (w,h) = creatingImage $ {#call wrapCreateImage32F#} (fromIntegral w) (fromIntegral h) 2
instance CreateImage (Image LAB D32) where
    create (w,h) = creatingImage $ {#call wrapCreateImage32F#} (fromIntegral w) (fromIntegral h) 3
instance CreateImage (Image RGB D32) where
    create (w,h) = creatingImage $ {#call wrapCreateImage32F#} (fromIntegral w) (fromIntegral h) 3
instance CreateImage (Image RGBA D32) where
    create (w,h) = creatingImage $ {#call wrapCreateImage32F#} (fromIntegral w) (fromIntegral h) 4

instance CreateImage (Image GrayScale D64) where
    create (w,h) = creatingImage $ {#call wrapCreateImage64F#} (fromIntegral w) (fromIntegral h) 1
instance CreateImage (Image LAB D64) where
    create (w,h) = creatingImage $ {#call wrapCreateImage64F#} (fromIntegral w) (fromIntegral h) 3
instance CreateImage (Image RGB D64) where
    create (w,h) = creatingImage $ {#call wrapCreateImage64F#} (fromIntegral w) (fromIntegral h) 3
instance CreateImage (Image RGBA D64) where
    create (w,h) = creatingImage $ {#call wrapCreateImage64F#} (fromIntegral w) (fromIntegral h) 4

instance CreateImage (Image GrayScale D8) where
    create (w,h) = creatingImage $ {#call wrapCreateImage8U#} (fromIntegral w) (fromIntegral h) 1
instance CreateImage (Image LAB D8) where
    create (w,h) = creatingImage $ {#call wrapCreateImage8U#} (fromIntegral w) (fromIntegral h) 3
instance CreateImage (Image RGB D8) where
    create (w,h) = creatingImage $ {#call wrapCreateImage8U#} (fromIntegral w) (fromIntegral h) 3
instance CreateImage (Image RGBA D8) where
    create (w,h) = creatingImage $ {#call wrapCreateImage8U#} (fromIntegral w) (fromIntegral h) 4

instance CreateImage (Image c d) => CreateImage (MutableImage c d) where
    create s = Mutable <$> create s


-- | Allocate a new empty image
empty :: (CreateImage (Image a b)) => (Int,Int) -> (Image a b)
empty size = unsafePerformIO $ create size

-- | Allocate a new image that of the same size and type as the exemplar image given.
emptyCopy :: (CreateImage (Image a b)) => Image a b -> (Image a b)
emptyCopy img = unsafePerformIO $ create (getSize img)

emptyCopy' :: (CreateImage (Image a b)) => Image a b -> IO (Image a b)
emptyCopy' img = create (getSize img)

-- | Save image. This will convert the image to 8 bit one before saving
class Save a where
    save :: FilePath -> a -> IO ()

instance Save (Image BGR D32) where
    save filename image = primitiveSave filename (unS . unsafeImageTo8Bit $ image)

instance Save (Image RGB D32) where
    save filename image = primitiveSave filename (swapRB . unS . unsafeImageTo8Bit $ image)

instance Save (Image RGB D8) where
    save filename image = primitiveSave filename  (swapRB . unS $ image)

instance Save (Image GrayScale D8) where
    save filename image = primitiveSave filename (unS $ image)

instance Save (Image GrayScale D32) where
    save filename image = primitiveSave filename (unS . unsafeImageTo8Bit $ image)

primitiveSave :: FilePath -> BareImage -> IO ()
primitiveSave filename fpi = do
       exists <- doesDirectoryExist (takeDirectory filename)
       when (not exists) $ throw (CvIOError $ "Directory does not exist: " ++ (takeDirectory filename))
       withCString  filename $ \name  ->
        withGenBareImage fpi    $ \cvArr ->
         alloca (\defs -> poke defs 0 >> {#call cvSaveImage #} name cvArr defs >> return ())

-- |Save an image as 8 bit gray scale
saveImage :: (Save (Image c d)) => FilePath -> Image c d ->  IO ()
saveImage = save

getArea :: (Sized a,Num b, Size a ~ (b,b)) => a -> b
getArea = uncurry (*).getSize

getRegion :: (Int,Int) -> (Int,Int) -> Image c d -> Image c d
getRegion (fromIntegral -> x,fromIntegral -> y) (fromIntegral -> w,fromIntegral -> h) image
    | x+w <= width && y+h <= height = S . getRegion' (x,y) (w,h) $ unS image
    | otherwise                   = error $ "Region outside image:"
                                            ++ show (getSize image) ++
                                            "/"++show (x+w,y+h)
 where
  (fromIntegral -> width,fromIntegral -> height) = getSize image

getRegion' (x,y) (w,h) image = unsafePerformIO $
                               withBareImage image $ \i ->
                                 creatingBareImage ({#call getSubImage#}
                                                i x y w h)


-- | Tile images by overlapping them on a black canvas.
tileImages image1 image2 (x,y) = unsafePerformIO $
                               withImage image1 $ \i1 ->
                                withImage image2 $ \i2 ->
                                 creatingImage ({#call simpleMergeImages#}
                                                i1 i2 x y)
-- | Blit image2 onto image1.
class Blittable channels depth 
instance Blittable GrayScale D32
instance Blittable RGB D32

blit :: Blittable c d => MutableImage c d -> Image c d -> (Int,Int) -> IO ()
blit image1 image2 (x,y) = do
    (w1,h1) <- getSize image1
    let ((w2,h2)) = getSize image2
    if x+w2>w1 || y+h2>h1 || x<0 || y<0
            then error $ "Bad blit sizes: " ++ show [(w1,h1),(w2,h2)]++"<-"++show (x,y)
            else withMutableImage image1 $ \i1 ->
                   withImage image2 $ \i2 -> 
                    ({#call plainBlit#} i1 i2 (fromIntegral y) (fromIntegral x))

-- | Create an image by blitting multiple images onto an empty image.
blitM :: (CreateImage (MutableImage GrayScale D32)) => 
    (Int,Int) -> [((Int,Int),Image GrayScale D32)] -> Image GrayScale D32
blitM (rw,rh) imgs = unsafePerformIO $ resultPic >>= fromMutable 
    where
     resultPic = do
                    r <- create (fromIntegral rw,fromIntegral rh)
                    sequence_ [blit r i (fromIntegral x, fromIntegral y)
                              | ((x,y),i) <- imgs ]
                    return r


subPixelBlit :: MutableImage c d -> Image c d -> (CDouble, CDouble) -> IO ()
subPixelBlit (image1) (image2) (x,y) = do
    (w1,h1) <- getSize image1
    let ((w2,h2)) = getSize image2
    if ceiling x+w2>w1 || ceiling y+h2>h1 || x<0 || y<0
     then error $ "Bad blit sizes: " ++ show [(w1,h1),(w2,h2)]++"<-"++show (x,y)
     else withMutableImage image1 $ \i1 ->
                   withImage image2 $ \i2 ->
                    ({#call subpixel_blit#} i1 i2 y x)

safeBlit i1 i2 (x,y) = unsafePerformIO $ do
                  res <- toMutable i1-- createImage32F (getSize i1) 1
                  blit res i2 (x,y)
                  return res

-- | Blit image2 onto image1.
--   This uses an alpha channel bitmap for determining the regions where the image should be "blended" with
--   the base image.
blendBlit :: MutableImage c d -> Image c1 d1 -> Image c3 d3 -> Image c2 d2
                      -> (CInt, CInt) -> IO ()
blendBlit image1 image1Alpha image2 image2Alpha (x,y) =
                               withMutableImage image1 $ \i1 ->
                                withImage image1Alpha $ \i1a ->
                                 withImage image2Alpha $ \i2a ->
                                  withImage image2 $ \i2 ->
                                   ({#call alphaBlit#} i1 i1a i2 i2a y x)


-- | Create a copy of an image
cloneImage :: Image a b -> IO (Image a b)
cloneImage img = withGenImage img $ \image ->
                    creatingImage ({#call cvCloneImage #} image)

toMutable :: Image a b -> IO (MutableImage a b)
toMutable img = withGenImage img $ \image ->
                    Mutable <$> creatingImage ({#call cvCloneImage #} image)

fromMutable :: MutableImage a b -> IO (Image a b)
fromMutable (Mutable img) = cloneImage img 

-- | Create a copy of a non-types image
cloneBareImage :: BareImage -> IO BareImage
cloneBareImage img = withGenBareImage img $ \image ->
                    creatingBareImage ({#call cvCloneImage #} image)

withMutableClone
  :: Image channels depth
     -> (MutableImage channels depth -> IO a)
     -> IO a
withMutableClone img fun = do
                result <- toMutable img
                fun result

withClone
  :: Image channels depth
     -> (Image channels depth -> IO ())
     -> IO (Image channels depth)
withClone img fun = do
                result <- cloneImage img
                fun result
                return result

withCloneValue
  :: Image channels depth
     -> (Image channels depth -> IO a)
     -> IO a
withCloneValue img fun = do
                result <- cloneImage img
                r <- fun result
                return r

cloneTo64F :: Image c d -> IO (Image c D64)
cloneTo64F img = withGenImage img $ \image ->
                creatingImage
                 ({#call ensure64F #} image)

-- | Convert an image to from arbitrary bit depth into 64 bit, floating point, image.
--   This conversion does preserve the color space.
-- Note: this function is named unsafe because it will lose information
-- from the image. 
unsafeImageTo64F :: Image c d -> Image c D64
unsafeImageTo64F img = unsafePerformIO $ withGenImage img $ \image ->
                creatingImage
                 ({#call ensure64F #} image)

-- | Convert an image to from arbitrary bit depth into 32 bit, floating point, image.
--   This conversion does preserve the color space.
-- Note: this function is named unsafe because it will lose information
-- from the image. 
unsafeImageTo32F :: Image c d -> Image c D32
unsafeImageTo32F img = unsafePerformIO $ withGenImage img $ \image ->
                creatingImage
                 ({#call ensure32F #} image)

-- | Convert an image to from arbitrary bit depth into 8 bit image.
--   This conversion does preserve the color space.
-- Note: this function is named unsafe because it will lose information
-- from the image. 
unsafeImageTo8Bit :: Image cspace a -> Image cspace D8
unsafeImageTo8Bit img =
    unsafePerformIO $ withGenImage img $ \image ->
              creatingImage ({#call ensure8U #} image)

--toD32 :: Image c d -> Image c D32
--toD32 i =
--  unsafePerformIO $
--    withImage i $ \i_ptr ->
--      creatingImage


imageTo32F img = withGenBareImage img $ \image ->
                creatingBareImage
                 ({#call ensure32F #} image)

imageTo8Bit img = withGenBareImage img $ \image ->
                creatingBareImage
                 ({#call ensure8U #} image)
#c
enum ImageDepth {
     Depth32F = IPL_DEPTH_32F,
     Depth64F = IPL_DEPTH_64F,
     Depth8U  = IPL_DEPTH_8U,
     Depth8S  = IPL_DEPTH_8S,
     Depth16U  = IPL_DEPTH_16U,
     Depth16S  = IPL_DEPTH_16S,
     Depth32S  = IPL_DEPTH_32S
     };
#endc

{#enum ImageDepth {}#}

deriving instance Show ImageDepth

getImageDepth :: Image c d -> IO ImageDepth
getImageDepth i = withImage i $ \c_img -> {#get IplImage->depth #} c_img >>= return.toEnum.fromIntegral
getImageChannels i = withImage i $ \c_img -> {#get IplImage->nChannels #} c_img

getImageInfo x = do
    let s = getSize x
    d <- getImageDepth x
    c <- getImageChannels x
    return (s,d,c)


-- | Set the region of interest for a mutable image
setROI :: (Integral a) => (a,a) -> (a,a) -> MutableImage c d -> IO ()
setROI (fromIntegral -> x,fromIntegral -> y)
       (fromIntegral -> w,fromIntegral -> h)
       image = withMutableImage image $ \i ->
                            {#call wrapSetImageROI#} i x y w h

-- | Set the region of interest to cover the entire image.
resetROI :: MutableImage c d -> IO ()
resetROI image = withMutableImage image $ \i ->
                  {#call cvResetImageROI#} i

setCOI :: (Enum a) => a -> MutableImage (ChannelOf a) d -> IO ()
setCOI chnl image = withMutableImage image $ \i ->
                            {#call cvSetImageCOI#} i (fromIntegral . (+1) . fromEnum $ chnl) 
                            -- CV numbers channels starting from 1. 0 means all channels

resetCOI :: MutableImage a d -> IO ()
resetCOI image = withMutableImage image $ \i ->
                  {#call cvSetImageCOI#} i 0


getChannel :: (Enum a) => a -> Image (ChannelOf a) d -> Image GrayScale d
getChannel no image = unsafePerformIO $ creatingImage $ do
    let (w,h) = getSize image
    mut <- toMutable image
    setCOI no mut
    cres <- {#call wrapCreateImage32F#} (fromIntegral w) (fromIntegral h) 1
    withMutableImage mut $ \cimage ->
      {#call cvCopy#} cimage (castPtr cres) (nullPtr)
    resetCOI mut
    return cres

withIOROI :: (Int,Int) -> (Int,Int) -> MutableImage c d -> IO a -> IO a
withIOROI pos size image op = do
            setROI pos size image
            x <- op
            resetROI image
            return x

--withROI :: (Int, Int) -> (Int, Int) -> Image c d -> (MutableImage c d -> a) -> a
--withROI pos size image op = unsafePerformIO $ do
--                        setROI pos size image
--                        let x = op image -- BUG
--                        resetROI image
--                        return x

class SetPixel a where
   type SP a :: *
   setPixel :: (Int,Int) -> SP a -> a -> IO ()

instance SetPixel (MutableImage GrayScale D32) where
   type SP (MutableImage GrayScale D32) = D32
   {-#INLINE setPixel#-}
   setPixel (x,y) v (image) = withMutableImage image $ \c_i -> do
                                  d <- {#get IplImage->imageData#} c_i
                                  s <- {#get IplImage->widthStep#} c_i
                                  poke (castPtr (d`plusPtr` (y*(fromIntegral s)
                                       + x*sizeOf (0::Float))):: Ptr Float)
                                       v

instance SetPixel (MutableImage GrayScale D8) where
   type SP (MutableImage GrayScale D8) = D8
   {-#INLINE setPixel#-}
   setPixel (x,y) v (image) = withMutableImage image $ \c_i -> do
                             d <- {#get IplImage->imageData#} c_i
                             s <- {#get IplImage->widthStep#} c_i
                             poke (castPtr (d`plusPtr` (y*(fromIntegral s)
                                  + x*sizeOf (0::Word8))):: Ptr Word8)
                                  v

instance SetPixel (MutableImage RGB D8) where
    type SP (MutableImage RGB D8) = (D8,D8,D8)
    {-#INLINE setPixel#-}
    setPixel (x,y) (r,g,b) (image) = withMutableImage image $ \c_i -> do
                                         d <- {#get IplImage->imageData#} c_i
                                         s <- {#get IplImage->widthStep#} c_i
                                         let cs = fromIntegral s
                                             fs = sizeOf (undefined :: D8)
                                         poke (castPtr (d`plusPtr` (y*cs +x*3*fs)))     b
                                         poke (castPtr (d`plusPtr` (y*cs +(x*3+1)*fs))) g
                                         poke (castPtr (d`plusPtr` (y*cs +(x*3+2)*fs))) r

instance SetPixel (MutableImage RGB D32) where
    type SP (MutableImage RGB D32) = (D32,D32,D32)
    {-#INLINE setPixel#-}
    setPixel (x,y) (r,g,b) (image) = withMutableImage image $ \c_i -> do
                                         d <- {#get IplImage->imageData#} c_i
                                         s <- {#get IplImage->widthStep#} c_i
                                         let cs = fromIntegral s
                                             fs = sizeOf (undefined :: Float)
                                         poke (castPtr (d`plusPtr` (y*cs +x*3*fs)))     b
                                         poke (castPtr (d`plusPtr` (y*cs +(x*3+1)*fs))) g
                                         poke (castPtr (d`plusPtr` (y*cs +(x*3+2)*fs))) r

instance SetPixel (MutableImage Complex D32) where
    type SP (MutableImage Complex D32) = C.Complex D32
    {-#INLINE setPixel#-}
    setPixel (x,y) (re C.:+ im) (image) = withMutableImage image $ \c_i -> do
                             d <- {#get IplImage->imageData#} c_i
                             s <- {#get IplImage->widthStep#} c_i
                             let cs = fromIntegral s
                                 fs = sizeOf (undefined :: Float)
                             poke (castPtr (d`plusPtr` (y*cs + x*2*fs))) re
                             poke (castPtr (d`plusPtr` (y*cs + (x*2+1)*fs))) im



getAllPixels image =  [getPixel (i,j) image
                      | i <- [0..width-1 ]
                      , j <- [0..height-1]]
                    where
                     (width,height) = getSize image

getAllPixelsRowMajor image =  [getPixel (i,j) image
                              | j <- [0..height-1]
                              , i <- [0..width-1]
                              ]
                    where
                     (width,height) = getSize image

-- |Create a montage form given images (u,v) determines the layout and space the spacing
--  between images. Images are assumed to be the same size (determined by the first image)
montage :: (Blittable c d) => (CreateImage (MutableImage c d)) => (Int,Int) -> Int -> [Image c d] -> Image c d
montage (u',v') space' imgs
    | u'*v' < (length imgs) = error ("Montage mismatch: "++show (u,v, length imgs))
    | otherwise              = resultPic
    where
     space = fromIntegral space'
     (u,v) = (fromIntegral u', fromIntegral v')
     (rw,rh) = (u*xstep,v*ystep)
     (w,h) = foldl (\(mx,my) (x,y) -> (max mx x, max my y)) (0,0) $ map getSize imgs
     (xstep,ystep) = (fromIntegral space + w,fromIntegral space + h)
     edge = space`div`2
     resultPic = unsafePerformIO $ do
                    r <- create (rw,rh)
                    sequence_ [blit r i (edge +  x*xstep, edge + y*ystep)
                               | y <- [0..v-1] , x <- [0..u-1]
                               | i <- imgs ]
                    let (Mutable i) = r 
                    i `seq` return i

data CvException = CvException Int String String String Int
     deriving (Show, Typeable)

data CvIOError = CvIOError String deriving (Show,Typeable)
data CvSizeError = CvSizeError String deriving (Show,Typeable)

instance Exception CvException
instance Exception CvIOError
instance Exception CvSizeError

setCatch = do
   let catch i cstr1 cstr2 cstr3 j = do
         func <- peekCString cstr1
         msg  <- peekCString cstr2
         file <- peekCString cstr3
         throw (CvException (fromIntegral i) func msg file (fromIntegral j))
         return 0
   cb <- mk'CvErrorCallback catch
   c'cvRedirectError cb nullPtr nullPtr
   c'cvSetErrMode c'CV_ErrModeSilent

