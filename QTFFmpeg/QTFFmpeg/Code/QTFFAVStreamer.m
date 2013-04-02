//
//  QTFFAVStreamer.m
//  QTFFmpeg
//
//  Created by Brad O'Hearne on 3/14/13.
//  Copyright (c) 2013 Big Hill Software LLC. All rights reserved.
//

#import "QTFFAVStreamer.h"
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
#import "NSError+Utils.h"
#import "QTFFAppLog.h"
#import "QTFFAVConfig.h"
#import "QTSampleBuffer+Utils.h"


@interface QTFFAVStreamer()
{
    AVFormatContext *_avOutputFormatContext;
    AVOutputFormat *_avOutputFormat;
    
    AVStream *_audioStream;
    AVFrame *_streamAudioFrame;
    
    AVStream *_videoStream;
    AVFrame *_inputVideoFrame;
    AVFrame *_streamVideoFrame;
    
    AVPacket _avPacket;
    
    int64_t _videoPresentationTime;
}

@end


@implementation QTFFAVStreamer

#pragma mark - Stream opening and closing

- (BOOL)openStream:(NSError **)error;
{
    @synchronized(self)
    {
        if (! _isStreaming)
        {
            // get the config
            QTFFAVConfig *config = [QTFFAVConfig sharedConfig];
            
            if (! (config.shouldStreamAudio || config.shouldStreamVideo))
            {
                if (error)
                {
                    NSString *message = @"Neither audio nor video was specified to be streamed, no stream opened.";
                    
                    *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                                 code:QTFFErrorCode_VideoStreamingError
                                          description:message];
                }
                
                return NO;
            }
            else
            {
                // log the stream name
                NSString *avContent = config.shouldStreamAudio ? (config.shouldStreamVideo ? @"audio/video" : @"audio only") : (config.shouldStreamVideo ? @"video only" : @"NULL");
                NSString *avOutputType = config.streamOutputStreamType == QTFFStreamTypeFile ? @"file" : @"network";
                QTFFAppLog(@"Opening %@ %@ stream: %@", avContent, avOutputType, config.streamOutputStreamName);
                
                if ([self loadLibraries:error])
                {
                    if ([self createOutputFormatContext:error])
                    {
                        if (config.shouldStreamAudio)
                        {
                            if (! [self createAudioStream:error])
                            {
                                // failed, error already set
                                
                                return NO;
                            }
                        }
                        
                        if (config.shouldStreamVideo)
                        {
                            if (! [self createVideoStream:error])
                            {
                                // failed, error already set
                                
                                return NO;
                            }
                            
                            _videoPresentationTime = 0;
                        }
                        
                        // create the options dictionary, add the appropriate headers
                        AVDictionary *options = NULL;
                        
                        const char *cStreamName = [config.streamOutputStreamName UTF8String];
                        
                        int returnVal = avio_open2(&_avOutputFormatContext->pb, cStreamName, AVIO_FLAG_READ_WRITE, nil, &options);
                        
                        if (returnVal != 0)
                        {
                            if (error)
                            {
                                NSString *message = [NSString stringWithFormat:@"Unable to open the stream output: %@, error: %d", config.streamOutputStreamName, returnVal];
                                
                                *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                                             code:QTFFErrorCode_VideoStreamingError
                                                      description:message];
                            }
                            
                            return NO;
                        }
                        
                        // some formats want stream headers to be separate
                        if(_avOutputFormatContext->oformat->flags & AVFMT_GLOBALHEADER)
                        {
                            if (config.shouldStreamAudio)
                            {
                                _audioStream->codec->flags |= CODEC_FLAG_GLOBAL_HEADER;
                            }
                            
                            if (config.shouldStreamVideo)
                            {
                                _videoStream->codec->flags |= CODEC_FLAG_GLOBAL_HEADER;
                            }
                        }
                        
                        // write the header
                        returnVal = avformat_write_header(_avOutputFormatContext, NULL);
                        if (returnVal != 0)
                        {
                            if (error)
                            {
                                *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                                             code:QTFFErrorCode_VideoStreamingError
                                                      description:[NSString stringWithFormat:@"Unable to write the stream header, error: %d", returnVal]];
                            }
                            
                            return NO;
                        }
                        
                        av_init_packet(&_avPacket);
                        
                        _isStreaming = YES;
                        
                        // everything succeeded
                        
                        return YES;
                    }
                    else
                    {
                        // output format context creation failed, error already set
                        
                        return NO;
                    }
                }
                else
                {
                    // load libraries failed, error already set
                    
                    return NO;
                }
            }
        }
        else
        {
            // already streaming
            
            return YES;
        }
    }
}

- (BOOL)loadLibraries:(NSError **)error;
{
    // initialize the error
    if (error)
    {
        *error = nil;
    }
    
    // initialize libavcodec, and register all codecs and formats
    av_register_all();
    
    // get the config
    QTFFAVConfig *config = [QTFFAVConfig sharedConfig];
    
    if (config.streamOutputStreamType == QTFFStreamTypeNetwork)
    {
        // initialize libavformat network capabilities
        int returnVal = avformat_network_init();
        if (returnVal != 0)
        {
            if (error)
            {
                NSString *message = [NSString stringWithFormat:@"Unable to initialize streaming networking library, error: %d", returnVal];
                
                *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                             code:QTFFErrorCode_VideoStreamingError
                                      description:message];
            }
            
            return NO;
        }
    }
    
    return YES;
}

- (BOOL)createOutputFormatContext:(NSError **)error;
{
    // get the config
    QTFFAVConfig *config = [QTFFAVConfig sharedConfig];
    
    // create the output format
    const char *cStreamName = [config.streamOutputStreamName UTF8String];
    const char *cFileNameExt = [config.streamOutputFilenameExtension UTF8String];
    const char *cMimeType = [config.streamOutputMIMEType UTF8String];
    
    _avOutputFormat = av_guess_format(cStreamName, cFileNameExt, cMimeType);
    
    if (! _avOutputFormat)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                         code:QTFFErrorCode_VideoStreamingError
                                  description:@"Unable to initialize the output stream handler format."];
        }
        
        return NO;
    }
    
    if (config.streamOutputStreamType == QTFFStreamTypeNetwork)
    {
        // set the no file flag so that the properties get set appropriately
        _avOutputFormat->flags = AVFMT_NOFILE;
    }
    
    // create the format context
    int returnVal = avformat_alloc_output_context2(&_avOutputFormatContext, _avOutputFormat, cFileNameExt, cStreamName);
    if (returnVal != 0)
    {
        if (error)
        {
            NSString *message = [NSString stringWithFormat:@"Unable to initialize the output format, error: %d", returnVal];
            
            *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                         code:QTFFErrorCode_VideoStreamingError
                                  description:message];
        }
        
        return NO;
    }
    
    return YES;
}

- (BOOL)createAudioStream:(NSError **)error;
{
    // create the audio stream
    _audioStream = nil;
    if (_avOutputFormat->audio_codec == CODEC_ID_NONE)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                         code:QTFFErrorCode_VideoStreamingError
                                  description:@"Unable to create a new audio stream, required codec unknown."];
        }
        
        return NO;
    }
    
    const AVCodec *audioCodec = avcodec_find_encoder(_avOutputFormat->audio_codec);
    
    QTFFAppLog(@"Audio codec: %s", audioCodec->name);
    
    _audioStream = avformat_new_stream(_avOutputFormatContext, audioCodec);
    
    if (! _audioStream)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                         code:QTFFErrorCode_VideoStreamingError
                                  description:[NSString stringWithFormat:@"Unable to create a new audio stream with codec: %u", _avOutputFormat->audio_codec]];
        }
        
        return NO;
    }
    
    AVCodecContext *audioCodecCtx = _audioStream->codec;
    
    // get the config
    QTFFAVConfig *config = [QTFFAVConfig sharedConfig];
    
    // set codec settings
    int bitRate = config.audioCodecBitRatePreferredKbps * 1000;
    audioCodecCtx->bit_rate = bitRate;
    audioCodecCtx->sample_rate = config.audioCodecSampleRate;
    audioCodecCtx->channel_layout = config.audioCodecChannelLayout;
    audioCodecCtx->channels = config.audioCodecNumberOfChannels;
    audioCodecCtx->sample_fmt = config.audioCodecSampleFormat;
    audioCodecCtx->codec_type = AVMEDIA_TYPE_AUDIO;
    audioCodecCtx->time_base.den = config.audioCodecSampleRate;
    //audioCodecCtx->time_base.den = config.videoCodecFrameRate;
    //audioCodecCtx->time_base.den = 30;
    audioCodecCtx->time_base.num = 1;
    
    if (avcodec_open2(audioCodecCtx, audioCodec, NULL) < 0)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                         code:QTFFErrorCode_VideoStreamingError
                                  description:@"Could not open audio codec."];
        }
        
        return NO;
    }
    
    // initialize the output audio frame
    _streamAudioFrame = avcodec_alloc_frame();
    
    return YES;
}

- (BOOL)createVideoStream:(NSError **)error;
{
    // create the video stream
    _videoStream = nil;
    if (_avOutputFormat->video_codec == CODEC_ID_NONE)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                         code:QTFFErrorCode_VideoStreamingError
                                  description:@"Unable to create a new video stream, required codec unknown."];
        }
        
        return NO;
    }
    
    const AVCodec *videoCodec = avcodec_find_encoder(_avOutputFormat->video_codec);
    _videoStream = avformat_new_stream(_avOutputFormatContext, videoCodec);
    
    if (! _videoStream)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                         code:QTFFErrorCode_VideoStreamingError
                                  description:[NSString stringWithFormat:@"Unable to create a new video stream with codec: %u", _avOutputFormat->video_codec]];
        }
        
        return NO;
    }
    
    // get the config
    QTFFAVConfig *config = [QTFFAVConfig sharedConfig];
    
    // set codec settings
    int bitRate = config.videoCodecBitRatePreferredKbps * 1000;
    
    AVCodecContext *videoCodecCtx = _videoStream->codec;
    videoCodecCtx->pix_fmt = config.videoCodecPixelFormat;
    videoCodecCtx->gop_size = config.videoCodecGOPSize;
    videoCodecCtx->width = config.videoCodecFrameWidth;
    videoCodecCtx->height = config.videoCodecFrameHeight;
    videoCodecCtx->bit_rate = bitRate;
    videoCodecCtx->time_base.den = config.videoCodecFrameRate;
    //videoCodecCtx->time_base.den = 15;
    videoCodecCtx->time_base.num = 1;
    
    // open the video codec
    if (avcodec_open2(videoCodecCtx, videoCodec, NULL) < 0)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                         code:QTFFErrorCode_VideoStreamingError
                                  description:@"Could not open video codec."];
        }
        
        return NO;
    }
    
    // initialize the input video frame
    _inputVideoFrame = [self videoFrameWithPixelFormat:config.videoInputPixelFormat
                                                 width:videoCodecCtx->width
                                                height:videoCodecCtx->height];
    
    // initialize the output video frame
    _streamVideoFrame = [self videoFrameWithPixelFormat:videoCodecCtx->pix_fmt
                                                  width:videoCodecCtx->width
                                                 height:videoCodecCtx->height];
    
    return YES;
}

- (BOOL)closeStream:(NSError **)error;
{
    @synchronized(self)
    {
        if (_isStreaming)
        {
            // flip the streaming flag
            _isStreaming = NO;
            
            // get the config
            QTFFAVConfig *config = [QTFFAVConfig sharedConfig];
            
            QTFFAppLog(@"Closing the video stream: %@", config.streamOutputStreamName);
            
            // initialize the error
            if (error)
            {
                *error = nil;
            }
            
            // write the trailer
            QTFFAppLog(@"Writing the video stream trailer.");
            int returnVal = av_write_trailer(_avOutputFormatContext);
            
            // free the context
            avformat_free_context(_avOutputFormatContext);
            _avOutputFormatContext = nil;
            _avOutputFormat = nil;
            
            // free the packet
            av_free_packet(&_avPacket);
            
            if (returnVal != 0)
            {
                if (error)
                {
                    *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                                 code:QTFFErrorCode_VideoStreamingError
                                          description:[NSString stringWithFormat:@"Unable to write the video stream trailer, error: %d", returnVal]];
                }
                
                return NO;
            }
        }
    }
    
    return YES;
}

#pragma mark - Frame streaming

- (BOOL)streamAudioFrame:(QTSampleBuffer *)sampleBuffer
                   error:(NSError **)error;
{
    @synchronized(self)
    {
        // get the config
        QTFFAVConfig *config = [QTFFAVConfig sharedConfig];
        
        if (config.shouldStreamAudio)
        {
            if (_isStreaming)
            {
                // get the codec context
                AVCodecContext *codecCtx = _audioStream->codec;
                
                //QTFFAppLog(@"%@", sampleBuffer.formatDescription.localizedFormatSummary);
                //QTFFAppLog(@"Bytes per frame:  %d", sampleBuffer.bytesPerFrame);
                //QTFFAppLog(@"Frames per packet:  %d", sampleBuffer.framesPerPacket);
                //QTFFAppLog(@"Is packed? %@", sampleBuffer.isPacked ? @"YES" : @"NO");
                //QTFFAppLog(@"Is high aligned? %@", sampleBuffer.isAlignedHigh ? @"YES" : @"NO");
                
                int sourceNumberOfChannels = sampleBuffer.channelsPerFrame;
                int64_t sourceChannelLayout = av_get_default_channel_layout(sourceNumberOfChannels);
                int sourceSampleRate = sampleBuffer.sampleRate;
                enum AVSampleFormat sourceSampleFormat = config.audioInputSampleFormat;
                int sourceLineSize = 0;
                int sourceNumberOfSamples = (int)(sampleBuffer.numberOfSamples);
                uint8_t **sourceData = NULL;
                
                // destination variables
                int64_t destinationChannelLayout = codecCtx->channel_layout;
                int destinationSampleRate = codecCtx->sample_rate;
                enum AVSampleFormat destinationSampleFormat = codecCtx->sample_fmt;
                int destinationNumberOfChannels = codecCtx->channels;
                int destinationLineSize = 0;
                uint8_t **destinationData = NULL;
                
                // resample the audio to convert to a format that FFmpeg can use
                
                // allocate a resampler context
                static struct SwrContext *resamplerCtx;
                
                //resamplerCtx = swr_alloc();
                
                resamplerCtx = swr_alloc_set_opts(NULL,
                                                  destinationChannelLayout,
                                                  destinationSampleFormat,
                                                  destinationSampleRate,
                                                  sourceChannelLayout,
                                                  sourceSampleFormat,
                                                  sourceSampleRate,
                                                  0,
                                                  NULL);
                
                if (resamplerCtx == NULL)
                {
                    if (error)
                    {
                        *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                                     code:QTFFErrorCode_VideoStreamingError
                                              description:@"Unable to create the resampler context for the audio frame."];
                    }
                    
                    return NO;
                }
                
                // initialize the resampling context
                int returnVal = swr_init(resamplerCtx);
                
                if (returnVal < 0)
                {
                    if (error)
                    {
                        NSString *description = [NSString stringWithFormat:@"Unable to init the resampler context, error: %d", returnVal];
                        *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                                     code:QTFFErrorCode_VideoStreamingError
                                              description:description];
                    }
                    
                    return NO;
                }
                
                // allocate the source samples buffer
                returnVal = alloc_samples_array_and_data(&sourceData,
                                                         &sourceLineSize,
                                                         sourceNumberOfChannels,
                                                         sourceNumberOfSamples,
                                                         sourceSampleFormat,
                                                         0);
                
                if (returnVal < 0)
                {
                    if (error)
                    {
                        NSString *description = [NSString stringWithFormat:@"Unable to allocate source samples, error: %d", returnVal];
                        *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                                     code:QTFFErrorCode_VideoStreamingError
                                              description:description];
                    }
                    
                    return NO;
                }
                
                /* compute destination number of samples */
                int destinationNumberOfSamples = (int)av_rescale_rnd(swr_get_delay(resamplerCtx, sourceSampleRate) +
                                                                     sourceNumberOfSamples, destinationSampleRate, sourceSampleRate, AV_ROUND_UP);
                
                // allocate the destination samples buffer
                returnVal = alloc_samples_array_and_data(&destinationData,
                                                         &destinationLineSize,
                                                         destinationNumberOfChannels,
                                                         destinationNumberOfSamples,
                                                         destinationSampleFormat,
                                                         0);
                
                if (returnVal < 0)
                {
                    if (error)
                    {
                        NSString *description = [NSString stringWithFormat:@"Unable to allocate destination samples, error: %d", returnVal];
                        *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                                     code:QTFFErrorCode_VideoStreamingError
                                              description:description];
                    }
                    
                    av_free(sourceData);
                    
                    return NO;
                }
                
                // assign source data
                AudioBufferList *tempAudioBufferList = [sampleBuffer audioBufferListWithOptions:0];
                sourceData[0] = tempAudioBufferList->mBuffers[0].mData;
                sourceData[1] = tempAudioBufferList->mBuffers[1].mData;
                
                // convert to destination format
                returnVal = swr_convert(resamplerCtx,
                                        destinationData,
                                        destinationNumberOfSamples,
                                        (const uint8_t **)sourceData,
                                        sourceNumberOfSamples);
                
                if (returnVal < 0)
                {
                    if (error)
                    {
                        NSString *description = [NSString stringWithFormat:@"Resampling failed, error: %d", returnVal];
                        *error = [NSError errorWithDomain:QTFFVideoErrorDomain code:QTFFErrorCode_VideoStreamingError description:description];
                    }
                    
                    av_free(sourceData);
                    av_free(destinationData);
                    
                    return NO;
                }
                
                int bufferSize = av_samples_get_buffer_size(&destinationLineSize,
                                                            destinationNumberOfChannels,
                                                            destinationNumberOfSamples,
                                                            destinationSampleFormat,
                                                            0);
                
                codecCtx->frame_size = (int)sampleBuffer.numberOfSamples;
                _streamAudioFrame->nb_samples = codecCtx->frame_size;
                _streamAudioFrame->format = codecCtx->sample_fmt;
                _streamAudioFrame->channel_layout = codecCtx->channel_layout;
                
                returnVal = avcodec_fill_audio_frame(_streamAudioFrame,
                                                     codecCtx->channels,
                                                     codecCtx->sample_fmt,
                                                     (const uint8_t*)destinationData[0],
                                                     bufferSize,
                                                     0);
                
                if (returnVal < 0)
                {
                    if (error)
                    {
                        *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                                     code:QTFFErrorCode_VideoStreamingError
                                              description:[NSString stringWithFormat:@"Unable to fill the audio frame with captured audio data, error: %d", returnVal]];
                    }
                    
                    av_free(sourceData);
                    av_free(destinationData);
                    
                    return NO;
                }
                
                // encode the audio frame, fill a packet for streaming
                _avPacket.data = NULL;
                _avPacket.size = 0;
                int gotPacket;
                
                /*
                 QTFFAppLog(@"Audio frame decode time: %lld", sampleBuffer.decodeTime.timeValue);
                 QTFFAppLog(@"Audio frame decode time scale: %ld", sampleBuffer.decodeTime.timeScale);
                 QTFFAppLog(@"Audio frame presentation time: %lld", sampleBuffer.presentationTime.timeValue);
                 QTFFAppLog(@"Audio frame presentation time scale: %ld", sampleBuffer.presentationTime.timeScale);
                 QTFFAppLog(@"Audio frame duration time: %lld", sampleBuffer.duration.timeValue);
                 QTFFAppLog(@"Audio frame duration time scale: %ld", sampleBuffer.duration.timeScale);
                 */
                
                _avPacket.pts = (((double)(sampleBuffer.presentationTime.timeValue * codecCtx->time_base.den)) / (double)sampleBuffer.presentationTime.timeScale);
                _avPacket.dts = (((double)(sampleBuffer.decodeTime.timeValue * codecCtx->time_base.den)) / (double)sampleBuffer.decodeTime.timeScale);
                _avPacket.duration = (((double)(sampleBuffer.duration.timeValue * codecCtx->time_base.den)) / (double)sampleBuffer.duration.timeScale);
                
                // encode the audio
                returnVal = avcodec_encode_audio2(codecCtx, &_avPacket, _streamAudioFrame, &gotPacket);
                
                if (returnVal != 0)
                {
                    if (error)
                    {
                        *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                                     code:QTFFErrorCode_VideoStreamingError
                                              description:[NSString stringWithFormat:@"Unable to encode the audio frame, error: %d", returnVal]];
                    }
                    
                    return NO;
                    
                    av_free(sourceData);
                    av_free(destinationData);
                }
                
                // if a packet was returned, write it to the network stream. The codec may take several calls before returning a packet.
                // only when there is a full packet returned for streaming should writing be attempted.
                if (gotPacket == 1)
                {
                    if (codecCtx->coded_frame->pts != AV_NOPTS_VALUE)
                    {
                        _avPacket.pts = av_rescale_q(codecCtx->coded_frame->pts, codecCtx->time_base, _audioStream->time_base);
                        //_avPacket.pts = av_rescale_q(codecCtx->coded_frame->pts, codecCtx->time_base, _videoStream->time_base);
                    }
                    
                    _avPacket.dts = _avPacket.pts;
                    
                    //QTFFAppLog(@"Audio frame pts: %lld", _avPacket.pts);
                    
                    _avPacket.flags |= AV_PKT_FLAG_KEY;
                    _avPacket.stream_index = _audioStream->index;
                    
                    // write the frame
                    //returnVal = av_interleaved_write_frame(_avOutputFormatContext, &avPacket);
                    returnVal = av_write_frame(_avOutputFormatContext, &_avPacket);
                    
                    if (returnVal != 0)
                    {
                        if (error)
                        {
                            *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                                         code:QTFFErrorCode_VideoStreamingError
                                                  description:[NSString stringWithFormat:@"Unable to write the audio frame to the stream, error: %d", returnVal]];
                        }
                        
                        av_free(sourceData);
                        av_free(destinationData);
                        
                        return NO;
                    }
                }
                
                //av_free(sourceData);
                //av_free(destinationData);
                
                return YES;
            }
            else
            {
                // not streaming
                
                if (error)
                {
                    NSString *message = @"Unable to stream the audio frame, as there is no stream open.";
                    
                    *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                                 code:QTFFErrorCode_VideoStreamingError
                                          description:message];
                }
                
                return NO;
            }
        }
        else
        {
            // not streaming audio, so treat as fine
            
            return YES;
        }
    }
}

- (BOOL)streamVideoFrame:(CVImageBufferRef)frameBuffer
            sampleBuffer:(QTSampleBuffer *)sampleBuffer
                   error:(NSError **)error;
{
    @synchronized(self)
    {
        // get the config
        QTFFAVConfig *config = [QTFFAVConfig sharedConfig];
        
        if (config.shouldStreamVideo)
        {
            if (_isStreaming)
            {
                // initialize the error
                if (error)
                {
                    *error = nil;
                }
                
                // lock the address of the frame pixel buffer
                CVPixelBufferLockBaseAddress(frameBuffer, 0);
                
                // get the frame's width and height
                int width = (int)CVPixelBufferGetWidth(frameBuffer);
                int height = (int)CVPixelBufferGetHeight(frameBuffer);
                
                unsigned char *frameBufferBaseAddress = (unsigned char *)CVPixelBufferGetBaseAddress(frameBuffer);
                
                // Do something with the raw pixels here
                CVPixelBufferUnlockBaseAddress(frameBuffer, 0);
                
                AVCodecContext *codecCtx = _videoStream->codec;
                
                // must stream a YUV420P picture, so convert the frame if needed
                static struct SwsContext *imgConvertCtx;
                static int sws_flags = SWS_BICUBIC;
                
                // create a convert context if necessary
                if (imgConvertCtx == NULL)
                {
                    imgConvertCtx = sws_getContext(width,
                                                   height,
                                                   config.videoInputPixelFormat,
                                                   codecCtx->width,
                                                   codecCtx->height,
                                                   codecCtx->pix_fmt,
                                                   sws_flags,
                                                   NULL,
                                                   NULL,
                                                   NULL);
                    
                    if (imgConvertCtx == NULL)
                    {
                        if (error)
                        {
                            *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                                         code:QTFFErrorCode_VideoStreamingError
                                                  description:@"Unable to create the image conversion context for the video frame."];
                        }
                        
                        return NO;
                    }
                }
                
                // take the input buffer and fill the input frame
                int returnVal = avpicture_fill((AVPicture*)_inputVideoFrame, frameBufferBaseAddress, config.videoInputPixelFormat, width, height);
                
                if (returnVal < 0)
                {
                    if (error)
                    {
                        *error = [NSError errorWithDomain:QTFFVideoErrorDomain code:QTFFErrorCode_VideoStreamingError description:[NSString stringWithFormat:@"Unable to fill the pre-conversion video frame with captured image data, error: %d", returnVal]];
                    }
                    
                    return NO;
                }
                
                // convert the input frame to an output frame for streaming
                sws_scale(imgConvertCtx, (const u_int8_t* const*)_inputVideoFrame->data, _inputVideoFrame->linesize,
                          0, codecCtx->height, _streamVideoFrame->data, _streamVideoFrame->linesize);
                
                /*
                 QTFFAppLog(@"Video frame decode time: %lld", sampleBuffer.decodeTime.timeValue);
                 QTFFAppLog(@"Video frame decode time scale: %ld", sampleBuffer.decodeTime.timeScale);
                 QTFFAppLog(@"Video frame presentation time: %lld", sampleBuffer.presentationTime.timeValue);
                 QTFFAppLog(@"Video frame presentation time scale: %ld", sampleBuffer.presentationTime.timeScale);
                 QTFFAppLog(@"Video frame duration time: %lld", sampleBuffer.duration.timeValue);
                 QTFFAppLog(@"Video frame duration time scale: %ld", sampleBuffer.duration.timeScale);
                 */
                
                //QTFFAppLog(@"Video frame presentation time: %lld", sampleBuffer.presentationTime.timeValue);
                //QTFFAppLog(@"Video frame duration time: %lld", sampleBuffer.duration.timeValue);
                
                //codecCtx->time_base.den = (int)(1.0 / ((double)sampleBuffer.duration.timeValue / (double)sampleBuffer.duration.timeScale));
                
                //int actualFrameRate = (int)(1.0 / ((double)sampleBuffer.duration.timeValue / (double)sampleBuffer.duration.timeScale));
                //QTFFAppLog(@"Video frame rate: %d", actualFrameRate);
                
                double timeBaseUnit = ((double)codecCtx->time_base.num / (double)codecCtx->time_base.den);
                
                int numberOfFramesToBeInserted = (int)(((double)sampleBuffer.duration.timeValue / (double)sampleBuffer.duration.timeScale) / timeBaseUnit);
                
                //int64_t presentationTime = (((double)(sampleBuffer.presentationTime.timeValue * codecCtx->time_base.den)) / (double)sampleBuffer.presentationTime.timeScale);

                //_avPacket.pts = (((double)(sampleBuffer.presentationTime.timeValue * codecCtx->time_base.den)) / (double)sampleBuffer.presentationTime.timeScale);
                //_avPacket.dts = _avPacket.pts;
                //_avPacket.dts = (((double)(sampleBuffer.decodeTime.timeValue * codecCtx->time_base.den)) / (double)sampleBuffer.decodeTime.timeScale);
                //_avPacket.duration = (((double)(sampleBuffer.duration.timeValue * codecCtx->time_base.den)) / (double)sampleBuffer.duration.timeScale);
                                
                for (int i = 0; i < numberOfFramesToBeInserted; i++)
                {
                    // encode the video frame, fill a packet for streaming
                    _avPacket.data = NULL;
                    _avPacket.size = 0;
                    int gotPacket;
                    
                    _avPacket.pts = ++_videoPresentationTime;
                    _avPacket.dts = _avPacket.pts;

                    // encoding
                    returnVal = avcodec_encode_video2(codecCtx, &_avPacket, _streamVideoFrame, &gotPacket);
                    
                    if (returnVal != 0)
                    {
                        if (error)
                        {
                            *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                                         code:QTFFErrorCode_VideoStreamingError
                                                  description:[NSString stringWithFormat:@"Unable to encode the video frame, error: %d", returnVal]];
                        }
                        
                        return NO;
                    }
                    
                    // if a packet was returned, write it to the network stream. The codec may take several calls before returning a packet.
                    // only when there is a full packet returned for streaming should writing be attempted.
                    if (gotPacket == 1)
                    {
                        if (codecCtx->coded_frame->pts != AV_NOPTS_VALUE)
                        {
                            _avPacket.pts = av_rescale_q(codecCtx->coded_frame->pts, codecCtx->time_base, _videoStream->time_base);
                        }
                        
                        if (_avPacket.pts == 0)
                        {
                            _avPacket.pts = 1;
                        }
                        
                        _avPacket.dts = _avPacket.pts;
                        
                        QTFFAppLog(@"Video frame pts: %lld", _avPacket.pts);
                        
                        //QTFFAppLog(@"Video frame duration: %d", _avPacket.duration);
                        
                        if(codecCtx->coded_frame->key_frame)
                        {
                            _avPacket.flags |= AV_PKT_FLAG_KEY;
                        }
                        
                        _avPacket.stream_index= _videoStream->index;
                        
                        // write the frame
                        //returnVal = av_interleaved_write_frame(_avOutputFormatContext, &avPacket);
                        returnVal = av_write_frame(_avOutputFormatContext, &_avPacket);
                        
                        if (returnVal != 0)
                        {
                            if (error)
                            {
                                *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                                             code:QTFFErrorCode_VideoStreamingError
                                                      description:[NSString stringWithFormat:@"Unable to write the video frame to the stream, error: %d", returnVal]];
                            }
                            
                            return NO;
                        }
                    }
                    
                    
                }
                
                return YES;
            }
            else
            {
                // not streaming
                
                if (error)
                {
                    NSString *message = @"Unable to stream the video frame, as there is no stream open.";
                    
                    *error = [NSError errorWithDomain:QTFFVideoErrorDomain
                                                 code:QTFFErrorCode_VideoStreamingError
                                          description:message];
                }
                
                return NO;
            }
        }
        else
        {
            // not streaming video, so treat as fine
            
            return YES;
        }
    }
}

#pragma mark - Helpers

- (AVFrame *)videoFrameWithPixelFormat:(enum AVPixelFormat)pixelFormat width:(int)width height:(int)height;
{
    AVFrame *frame;
    uint8_t *frameBuffer;
    int size;
    
    frame = avcodec_alloc_frame();
    
    if (frame)
    {
        size = avpicture_get_size(pixelFormat, width, height);
        frameBuffer = av_malloc(size);
        
        if (! frameBuffer) {
            av_free(frameBuffer);
            return nil;
        }
        
        avpicture_fill((AVPicture *)frame, frameBuffer, pixelFormat, width, height);
    }
    else
    {
        QTFFAppLog(@"Can't allocate video frame.");
    }
    
    return frame;
}

int alloc_samples_array_and_data(uint8_t ***data,
                                 int *linesize,
                                 int nb_channels,
                                 int nb_samples,
                                 enum AVSampleFormat sample_fmt,
                                 int align)
{
    int nb_planes = av_sample_fmt_is_planar(sample_fmt) ? nb_channels : 1;
    
    *data = av_malloc(sizeof(*data) * nb_planes);
    if (!*data)
        return AVERROR(ENOMEM);
    return av_samples_alloc(*data, linesize, nb_channels,
                            nb_samples, sample_fmt, align);
}


@end
