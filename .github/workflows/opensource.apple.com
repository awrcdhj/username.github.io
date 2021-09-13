/*
 * Copyright (c) 2000-2008 Apple Inc. All Rights Reserved.
 * 
 * The contents of this file constitute Original Code as defined in and are
 * subject to the Apple Public Source License Version 1.2 (the 'License').
 * You may not use this file except in compliance with the License. Please obtain
 * a copy of the License at http://www.apple.com/publicsource and read it before
 * using this file.
 * 
 * This Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESS
 * OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES, INCLUDING WITHOUT
 * LIMITATION, ANY WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
 * PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT. Please see the License for the
 * specific language governing rights and limitations under the License.
 */


/*
	File:		SecureTransport.h

	Contains:	Public API for Apple SSL/TLS Implementation

	Copyright: (c) 1999-2008 Apple Inc. All Rights Reserved.

*/

#ifndef _SECURITY_SECURETRANSPORT_H_
#define _SECURITY_SECURETRANSPORT_H_

/*
 * This file describes the public API for an implementation of the 
 * Secure Socket Layer, V. 3.0, and Transport Layer Security, V. 1.0.
 *
 * There no transport layer dependencies in this library;
 * it can be used with sockets, Open Transport, etc. Applications using
 * this library provide callback functions which do the actual I/O
 * on underlying network connections. Applications are also responsible
 * for setting up raw network connections; the application passes in
 * an opaque reference to the underlying (connected) entity at the 
 * start of an SSL session in the form of an SSLConnectionRef.
 *
 * Some terminology:
 *
 * A "client" is the initiator of an SSL Session. The canonical example
 * of a client is a web browser, when it's talking to an https URL. 
 *
 * A "server" is an entity which accepts requests for SSL sessions made
 * by clients. E.g., a secure web server. 
 
 * An "SSL Session", or "session", is bounded by calls to SSLHandshake()
 * and SSLClose(). An "Active session" is in some state between these
 * two calls, inclusive.
 * 
 * An SSL Session Context, or SSLContextRef, is an opaque reference in this
 * library to the state associated with one session. A SSLContextRef cannot
 * be reused for multiple sessions.  
 */ 
 
#include <CoreFoundation/CFArray.h>
#include <Security/CipherSuite.h>
#include <Security/SecTrust.h>
#include <sys/types.h>
#include <AvailabilityMacros.h>

#ifdef __cplusplus
extern "C" {
#endif

/***********************
 *** Common typedefs ***
 ***********************/
 
/* Opaque reference to an SSL session context */
struct                      SSLContext;
typedef struct SSLContext   *SSLContextRef;

/* Opaque reference to an I/O conection (socket, Endpoint, etc.) */
typedef const void *		SSLConnectionRef;

/* SSL Protocol version */
typedef enum {
	kSSLProtocolUnknown,		/* no protocol negotiated/specified; use default */
	kSSLProtocol2,				/* SSL 2.0 only */
	kSSLProtocol3,				/* SSL 3.0 preferred, 2.0 OK if peer requires */
	kSSLProtocol3Only,			/* use SSL 3.0 only, fail if peer tries to
								 * negotiate 2.0 */
	kTLSProtocol1,				/* TLS 1.0 preferred, lower versions OK */
	kTLSProtocol1Only,			/* TLS 1.0 only */
	kSSLProtocolAll				/* all supported versions */
} SSLProtocol;

/* SSL session options */
typedef enum {
	/* 
	 * Set this option to enable returning from SSLHandshake (with a result of
	 * errSSLServerAuthCompleted) when the server authentication portion of the
	 * handshake is complete. If certificate verification has been disabled
	 * (via SSLSetEnableCertVerify), this provides an opportunity to perform
	 * application-specific server verification before deciding to continue.
	 */
	kSSLSessionOptionBreakOnServerAuth,
	/*
	 * Set this option to enable returning from SSLHandshake (with a result of
	 * errSSLClientCertRequested) when the server requests a client certificate.
	 */
	kSSLSessionOptionBreakOnCertRequested
} SSLSessionOption;

/* State of an SSLSession */
typedef enum {
	kSSLIdle,					/* no I/O performed yet */
	kSSLHandshake,				/* SSL handshake in progress */
	kSSLConnected,				/* Handshake complete, ready for normal I/O */
	kSSLClosed,					/* connection closed normally */
	kSSLAborted					/* connection aborted */
} SSLSessionState;

/* 
 * Status of client certificate exchange (which is optional
 * for both server and client).
 */
typedef enum {
	/* Server hasn't asked for a cert. Client hasn't sent one. */
	kSSLClientCertNone, 
	/* Server has asked for a cert, but client didn't send it. */
	kSSLClientCertRequested,
	/*
	 * Server side: We asked for a cert, client sent one, we validated 
	 *				it OK. App can inspect the cert via 
	 *				SSLGetPeerCertificates().
	 * Client side: server asked for one, we sent it.
	 */
	kSSLClientCertSent,
	/*
	 * Client sent a cert but failed validation. Server side only.
	 * Server app can inspect the cert via SSLGetPeerCertificates().
	 */
	kSSLClientCertRejected
} SSLClientCertificateState;

/* 
 * R/W functions. The application using this library provides
 * these functions via SSLSetIOFuncs().
 *
 * Data's memory is allocated by caller; on entry to these two functions
 * the *length argument indicates both the size of the available data and the
 * requested byte count. Number of bytes actually transferred is returned in 
 * *length.
 *
 * The application may configure the underlying connection to operate
 * in a non-blocking manner; in such a case, a read operation may
 * well return errSSLWouldBlock, indicating "I transferred less data than
 * you requested (maybe even zero bytes), nothing is wrong, except 
 * requested I/O hasn't completed". This will be returned back up to 
 * the application as a return from SSLRead(), SSLWrite(), SSLHandshake(),
 * etc. 
 */
typedef OSStatus 
(*SSLReadFunc) 				(SSLConnectionRef 	connection,
							 void 				*data, 			/* owned by 
							 									 * caller, data
							 									 * RETURNED */
							 size_t 			*dataLength);	/* IN/OUT */ 
typedef OSStatus 
(*SSLWriteFunc) 			(SSLConnectionRef 	connection,
							 const void 		*data, 
							 size_t 			*dataLength);	/* IN/OUT */ 


/*************************************************
 *** OSStatus values unique to SecureTransport ***
 *************************************************/

/*
    Note: the comments that appear after these errors are used to create SecErrorMessages.strings.
    The comments must not be multi-line, and should be in a form meaningful to an end user. If
    a different or additional comment is needed, it can be put in the header doc format, or on a
    line that does not start with errZZZ.
*/

enum {
	errSSLProtocol				= -9800,	/* SSL protocol error */
	errSSLNegotiation			= -9801,	/* Cipher Suite negotiation failure */
	errSSLFatalAlert			= -9802,	/* Fatal alert */
	errSSLWouldBlock			= -9803,	/* I/O would block (not fatal) */
    errSSLSessionNotFound 		= -9804,	/* attempt to restore an unknown session */
    errSSLClosedGraceful 		= -9805,	/* connection closed gracefully */
    errSSLClosedAbort 			= -9806,	/* connection closed via error */
    errSSLXCertChainInvalid 	= -9807,	/* invalid certificate chain */
    errSSLBadCert				= -9808,	/* bad certificate format */
	errSSLCrypto				= -9809,	/* underlying cryptographic error */
	errSSLInternal				= -9810,	/* Internal error */
	errSSLModuleAttach			= -9811,	/* module attach failure */
    errSSLUnknownRootCert		= -9812,	/* valid cert chain, untrusted root */
    errSSLNoRootCert			= -9813,	/* cert chain not verified by root */
	errSSLCertExpired			= -9814,	/* chain had an expired cert */
	errSSLCertNotYetValid		= -9815,	/* chain had a cert not yet valid */
	errSSLClosedNoNotify		= -9816,	/* server closed session with no notification */
	errSSLBufferOverflow		= -9817,	/* insufficient buffer provided */
	errSSLBadCipherSuite		= -9818,	/* bad SSLCipherSuite */
	
	/* fatal errors detected by peer */
	errSSLPeerUnexpectedMsg		= -9819,	/* unexpected message received */
	errSSLPeerBadRecordMac		= -9820,	/* bad MAC */
	errSSLPeerDecryptionFail	= -9821,	/* decryption failed */
	errSSLPeerRecordOverflow	= -9822,	/* record overflow */
	errSSLPeerDecompressFail	= -9823,	/* decompression failure */
	errSSLPeerHandshakeFail		= -9824,	/* handshake failure */
	errSSLPeerBadCert			= -9825,	/* misc. bad certificate */
	errSSLPeerUnsupportedCert	= -9826,	/* bad unsupported cert format */
	errSSLPeerCertRevoked		= -9827,	/* certificate revoked */
	errSSLPeerCertExpired		= -9828,	/* certificate expired */
	errSSLPeerCertUnknown		= -9829,	/* unknown certificate */
	errSSLIllegalParam			= -9830,	/* illegal parameter */
	errSSLPeerUnknownCA 		= -9831,	/* unknown Cert Authority */
	errSSLPeerAccessDenied		= -9832,	/* access denied */
	errSSLPeerDecodeError		= -9833,	/* decoding error */
	errSSLPeerDecryptError		= -9834,	/* decryption error */
	errSSLPeerExportRestriction	= -9835,	/* export restriction */
	errSSLPeerProtocolVersion	= -9836,	/* bad protocol version */
	errSSLPeerInsufficientSecurity = -9837,	/* insufficient security */
	errSSLPeerInternalError		= -9838,	/* internal error */
	errSSLPeerUserCancelled		= -9839,	/* user canceled */
	errSSLPeerNoRenegotiation	= -9840,	/* no renegotiation allowed */

	/* non-fatal result codes */
	errSSLServerAuthCompleted	= -9841,	/* server cert is valid, or was ignored if verification disabled */
	errSSLClientCertRequested	= -9842,	/* server has requested a client cert */

	/* more errors detected by us */
	errSSLHostNameMismatch		= -9843,	/* peer host name mismatch */
	errSSLConnectionRefused		= -9844,	/* peer dropped connection before responding */
	errSSLDecryptionFail		= -9845,	/* decryption failure */
	errSSLBadRecordMac			= -9846,	/* bad MAC */
	errSSLRecordOverflow		= -9847,	/* record overflow */
	errSSLBadConfiguration		= -9848,	/* configuration error */
	errSSLLast					= -9849		/* end of range, to be deleted */
};


/******************
 *** Public API ***
 ******************/

/* 
 * Create a new session context.
 */
OSStatus
SSLNewContext				(Boolean 			isServer,
							 SSLContextRef 		*contextPtr);	/* RETURNED */

/*
 * Dispose of an SSLContextRef.
 */
OSStatus
SSLDisposeContext			(SSLContextRef		context);

/*
 * Determine the state of an SSL session.
 */
OSStatus 
SSLGetSessionState			(SSLContextRef		context,
							 SSLSessionState	*state);	/* RETURNED */

/*
 * Set options for an SSL session. Must be called prior to SSLHandshake();
 * subsequently cannot be called while session is active.
 */
OSStatus
SSLSetSessionOption			(SSLContextRef		context,
							 SSLSessionOption	option,
							 Boolean			value);

/*
 * Determine current value for the specified option in a given SSL session.
 */
OSStatus
SSLGetSessionOption			(SSLContextRef		context,
							 SSLSessionOption	option,
							 Boolean			*value);
	
/********************************************************************
 *** Session context configuration, common to client and servers. ***
 ********************************************************************/
 
/* 
 * Specify functions which do the network I/O. Must be called prior
 * to SSLHandshake(); subsequently cannot be called while a session is
 * active. 
 */
OSStatus 
SSLSetIOFuncs				(SSLContextRef		context, 
							 SSLReadFunc 		read,
							 SSLWriteFunc		write);

/*
 * Set allowed SSL protocol versions. Optional. 
 * Specifying kSSLProtocolAll for SSLSetProtocolVersionEnabled results in 
 * specified 'enable' boolean to be applied to all supported protocols.
 * The default is "all supported protocols are enabled". 
 * This can only be called when no session is active.
 *
 * Legal values for protocol are :
 *		kSSLProtocol2
 *		kSSLProtocol3
 * 		kTLSProtocol1
 *		kSSLProtocolAll
 */
OSStatus 
SSLSetProtocolVersionEnabled (SSLContextRef 	context,
							 SSLProtocol		protocol,
							 Boolean			enable);
							 
/*
 * Obtain a value specified in SSLSetProtocolVersionEnabled.
 */
OSStatus 
SSLGetProtocolVersionEnabled(SSLContextRef 		context,
							 SSLProtocol		protocol,
							 Boolean			*enable);		/* RETURNED */

/* 
 * Get/set SSL protocol version; optional. Default is kSSLProtocolUnknown, 
 * in which case the highest possible version (currently kTLSProtocol1) 
 * is attempted, but a lower version is accepted if the peer requires it. 
 *
 * SSLSetProtocolVersion can not be called when a session is active. 
 *
 * This is deprecated in favor of SSLSetProtocolVersionEnabled.
 */
OSStatus 
SSLSetProtocolVersion		(SSLContextRef 		context,
							 SSLProtocol		version);

/*
 * Obtain the protocol version specified in SSLSetProtocolVersion.
 * This is deprecated in favor of SSLGetProtocolVersionEnabled. 
 * If SSLSetProtocolVersionEnabled() has been called for this session,
 * SSLGetProtocolVersion() may return paramErr if the protocol enable
 * state can not be represented by the SSLProtocol enums (e.g.,
 * SSL2 and TLS1 enabled, SSL3 disabled). 
 */
OSStatus 
SSLGetProtocolVersion		(SSLContextRef		context,
							 SSLProtocol		*protocol);		/* RETURNED */

/*
 * Specify this connection's certificate(s). This is mandatory for
 * server connections, optional for clients. Specifying a certificate
 * for a client enables SSL client-side authentication. The end-entity
 * cert is in certRefs[0]. Specifying a root cert is optional; if it's
 * not specified, the root cert which verifies the cert chain specified
 * here must be present in the system-wide set of trusted anchor certs.
 *
 * The certRefs argument is a CFArray containing SecCertificateRefs,
 * except for certRefs[0], which is a SecIdentityRef.
 *
 * Must be called prior to SSLHandshake(), or immediately after
 * SSLHandshake has returned errSSLClientCertRequested (i.e. before the
 * handshake is resumed by calling SSLHandshake again.)
 *
 * SecureTransport assumes the following:
 *   
 *	-- The certRef references remains valid for the lifetime of the 
 *     session.
 *  -- The specified certRefs[0] is capable of signing. 
 *  -- The required capabilities of the certRef[0], and of the optional cert
 *     specified in SSLSetEncryptionCertificate (see below), are highly
 *     dependent on the application. For example, to work as a server with
 *     Netscape clients, the cert specified here must be capable of both
 *     signing and encrypting. 
 */
OSStatus
SSLSetCertificate			(SSLContextRef		context,
							 CFArrayRef			certRefs);

/*
 * Specify I/O connection - a socket, endpoint, etc., which is
 * managed by caller. On the client side, it's assumed that communication
 * has been established with the desired server on this connection.
 * On the server side, it's assumed that an incoming client request
 * has been established. 
 *
 * Must be called prior to SSLHandshake(); subsequently can only be
 * called when no session is active.
 */
OSStatus
SSLSetConnection			(SSLContextRef		context,
							 SSLConnectionRef	connection);

OSStatus
SSLGetConnection			(SSLContextRef		context,
							 SSLConnectionRef	*connection);
							 
/* 
 * Specify the fully qualified doman name of the peer, e.g., "store.apple.com."
 * Optional; used to verify the common name field in peer's certificate. 
 * Name is in the form of a C string; NULL termination optional, i.e., 
 * peerName[peerNameLen+1] may or may not have a NULL. In any case peerNameLen
 * is the number of bytes of the peer domain name.
 */
OSStatus
SSLSetPeerDomainName		(SSLContextRef		context,
							 const char			*peerName,
							 size_t				peerNameLen);
							 
/*
 * Determine the buffer size needed for SSLGetPeerDomainName().
 */
OSStatus 
SSLGetPeerDomainNameLength	(SSLContextRef		context,
							 size_t				*peerNameLen);	// RETURNED

/*
 * Obtain the value specified in SSLSetPeerDomainName().
 */
OSStatus 
SSLGetPeerDomainName		(SSLContextRef		context,
							 char				*peerName,		// returned here
							 size_t				*peerNameLen);	// IN/OUT

/*
 * Obtain the actual negotiated protocol version of the active
 * session, which may be different that the value specified in 
 * SSLSetProtocolVersion(). Returns kSSLProtocolUnknown if no 
 * SSL session is in progress.
 */
OSStatus 
SSLGetNegotiatedProtocolVersion		(SSLContextRef		context,
									 SSLProtocol		*protocol); /* RETURNED */

/*
 * Determine number and values of all of the SSLCipherSuites we support.
 * Caller allocates output buffer for SSLGetSupportedCiphers() and passes in
 * its size in *numCiphers. If supplied buffer is too small, errSSLBufferOverflow
 * will be returned. 
 */
OSStatus
SSLGetNumberSupportedCiphers (SSLContextRef			context,
							  size_t				*numCiphers);
			
OSStatus
SSLGetSupportedCiphers		 (SSLContextRef			context,
							  SSLCipherSuite		*ciphers,		/* RETURNED */
							  size_t				*numCiphers);	/* IN/OUT */

/*
 * Specify a (typically) restricted set of SSLCipherSuites to be enabled by
 * the current SSLContext. Can only be called when no session is active. Default
 * set of enabled SSLCipherSuites is the same as the complete set of supported 
 * SSLCipherSuites as obtained by SSLGetSupportedCiphers().
 */
OSStatus 
SSLSetEnabledCiphers		(SSLContextRef			context,
							 const SSLCipherSuite	*ciphers,	
							 size_t					numCiphers);
							 
/*
 * Determine number and values of all of the SSLCipherSuites currently enabled.
 * Caller allocates output buffer for SSLGetEnabledCiphers() and passes in
 * its size in *numCiphers. If supplied buffer is too small, errSSLBufferOverflow
 * will be returned. 
 */
OSStatus
SSLGetNumberEnabledCiphers 	(SSLContextRef			context,
							 size_t					*numCiphers);
			
OSStatus
SSLGetEnabledCiphers		(SSLContextRef			context,
							 SSLCipherSuite			*ciphers,		/* RETURNED */
							 size_t					*numCiphers);	/* IN/OUT */

/*
 * Enable/disable peer certificate chain validation. Default is enabled.
 * If caller disables, it is the caller's responsibility to call 
 * SSLGetPeerCertificates() upon successful completion of the handshake
 * and then to perform external validation of the peer certificate
 * chain before proceeding with data transfer.
 */
OSStatus
SSLSetEnableCertVerify		(SSLContextRef 			context,
							 Boolean				enableVerify);
							 
OSStatus
SSLGetEnableCertVerify		(SSLContextRef 			context,
							 Boolean				*enableVerify);	/* RETURNED */


/*
 * Specify the option of ignoring certificates' "expired" times. 
 * This is a common failure in the real SSL world. Default for 
 * this flag is false, meaning expired certs result in a
 * errSSLCertExpired error.
 */ 
OSStatus 
SSLSetAllowsExpiredCerts	(SSLContextRef		context,
							 Boolean			allowsExpired);
							 
/* 
 * Obtain the current value of an SSLContext's "allowExpiredCerts" flag. 
 */
OSStatus
SSLGetAllowsExpiredCerts	(SSLContextRef		context,
							 Boolean			*allowsExpired); /* RETURNED */

/*
 * Similar to SSLSetAllowsExpiredCerts(), this function allows the 
 * option of ignoring "expired" status for root certificates only.
 * Default is false, i.e., expired root certs result in an 
 * errSSLCertExpired error.
 */
OSStatus 
SSLSetAllowsExpiredRoots	(SSLContextRef		context,
							 Boolean			allowsExpired);
							 
OSStatus
SSLGetAllowsExpiredRoots	(SSLContextRef		context,
							 Boolean			*allowsExpired); /* RETURNED */

/*
 * Specify option of allowing for an unknown root cert, i.e., one which
 * this software can not verify as one of a list of known good root certs. 
 * Default for this flag is false, in which case one of the following two
 * errors may occur:
 *    -- The peer returns a cert chain with a root cert, and the chain 
 *       verifies to that root, but the root is not one of our trusted
 *       roots. This results in errSSLUnknownRootCert on handshake. 
 *    -- The peer returns a cert chain which does not contain a root cert,
 *       and we can't verify the chain to one of our trusted roots. This 
 *       results in errSSLNoRootCert on handshake.
 *
 * Both of these error conditions are ignored when the AllowAnyRoot flag is true,
 * allowing connection to a totally untrusted peer. 
 */
OSStatus 
SSLSetAllowsAnyRoot			(SSLContextRef		context,
							 Boolean			anyRoot);

/* 
 * Obtain the current value of an SSLContext's "allow any root" flag. 
 */
OSStatus
SSLGetAllowsAnyRoot			(SSLContextRef		context,
							 Boolean			*anyRoot); /* RETURNED */

/*
 * Augment or replace the system's default trusted root certificate set
 * for this session. If replaceExisting is true, the specified roots will
 * be the only roots which are trusted during this session. If replaceExisting
 * is false, the specified roots will be added to the current set of trusted
 * root certs. If this function has never been called, the current trusted
 * root set is the same as the system's default trusted root set.
 * Successive calls with replaceExisting false result in accumulation
 * of additional root certs.
 *
 * The trustedRoots array contains SecCertificateRefs.
 */ 
OSStatus 
SSLSetTrustedRoots			(SSLContextRef 		context,
							 CFArrayRef 		trustedRoots,
							 Boolean 			replaceExisting); 

/*
 * Obtain an array of SecCertificateRefs representing the current
 * set of trusted roots. If SSLSetTrustedRoots() has never been called
 * for this session, this returns the system's default root set.
 *
 * Caller must CFRelease the returned CFArray and each SecCertificateRef
 * in the array. For this reason this is deprecated in favor of 
 * SSLCopyTrustedRoots(), which has proper CF semantics. 
 */
OSStatus 
SSLGetTrustedRoots			(SSLContextRef 		context,
							 CFArrayRef 		*trustedRoots)	/* RETURNED */
							 DEPRECATED_IN_MAC_OS_X_VERSION_10_5_AND_LATER;

 /*
  * Obtain an array of SecCertificateRefs representing the current
  * set of trusted roots. If SSLSetTrustedRoots() has never been called
  * for this session, this returns the system's default root set.
  *
  * Caller must CFRelease the returned CFArray. 
  */
OSStatus 
SSLCopyTrustedRoots			(SSLContextRef 		context,
							 CFArrayRef 		*trustedRoots);	/* RETURNED */

														 
/*
 * Request peer certificates. Valid anytime, subsequent to
 * a handshake attempt.
 *
 * The certs argument is a CFArray containing SecCertificateRefs.
 * Caller must CFRelease the returned array as well as each 
 * SecCertificateRef in it. For this reason this function is 
 * deprecated in favor of SSLCopyPeerCertificates(). 
 * 
 * The cert at index 0 of the returned array is the subject (end 
 * entity) cert; the root cert (or the closest cert to it) is at 
 * the end of the returned array. 
 */	
OSStatus 
SSLGetPeerCertificates		(SSLContextRef 		context, 
							 CFArrayRef			*certs)		/* RETURNED */
							 DEPRECATED_IN_MAC_OS_X_VERSION_10_5_AND_LATER;

/*
 * Request peer certificates. Valid anytime, subsequent to
 * a handshake attempt.
 *
 * The certs argument is a CFArray containing SecCertificateRefs.
 * Caller must CFRelease the returned array.
 * 
 * The cert at index 0 of the returned array is the subject (end 
 * entity) cert; the root cert (or the closest cert to it) is at 
 * the end of the returned array. 
 */	
OSStatus 
SSLCopyPeerCertificates		(SSLContextRef 		context, 
							 CFArrayRef			*certs);	/* RETURNED */

/*
 * Obtain a SecTrustRef representing peer certificates. Valid anytime,
 * subsequent to a handshake attempt. Caller must CFRelease the returned
 * trust reference.
 */
OSStatus
SSLCopyPeerTrust			(SSLContextRef 		context,
							 SecTrustRef		*trust);	/* RETURNED */

/*
 * Specify some data, opaque to this library, which is sufficient
 * to uniquely identify the peer of the current session. An example
 * would be IP address and port, stored in some caller-private manner.
 * To be optionally called prior to SSLHandshake for the current 
 * session. This is mandatory if this session is to be resumable. 
 *
 * SecureTransport allocates its own copy of the incoming peerID. The 
 * data provided in *peerID, while opaque to SecureTransport, is used
 * in a byte-for-byte compare to other previous peerID values set by the 
 * current application. Matching peerID blobs result in SecureTransport
 * attempting to resume an SSL session with the same parameters as used
 * in the previous session which specified the same peerID bytes. 
 */
OSStatus 
SSLSetPeerID				(SSLContextRef 		context, 
							 const void 		*peerID,
							 size_t				peerIDLen);

/*
 * Obtain current PeerID. Returns NULL pointer, zero length if
 * SSLSetPeerID has not been called for this context.
 */
OSStatus
SSLGetPeerID				(SSLContextRef 		context, 
							 const void 		**peerID,
							 size_t				*peerIDLen);

/*
 * Obtain the SSLCipherSuite (e.g., SSL_RSA_WITH_DES_CBC_SHA) negotiated
 * for this session. Only valid when a session is active.
 */
OSStatus 
SSLGetNegotiatedCipher		(SSLContextRef 		context,
							 SSLCipherSuite 	*cipherSuite);


/********************************************************
 *** Session context configuration, server side only. ***
 ********************************************************/
				 
/*
 * Specify this connection's encryption certificate(s). This is
 * used in one of the following cases:
 *
 *	-- The end-entity certificate specified in SSLSetCertificate() is 
 *	   not capable of encryption.  
 *
 *  -- The end-entity certificate specified in SSLSetCertificate() 
 * 	   contains a key which is too large (i.e., too strong) for legal 
 *	   encryption in this session. In this case a weaker cert is 
 *     specified here and is used for server-initiated key exchange. 
 *
 * The certRefs argument is a CFArray containing SecCertificateRefs,
 * except for certRefs[0], which is a SecIdentityRef.
 *
 * The following assumptions are made:
 *
 *	-- The certRefs references remains valid for the lifetime of the 
 *     connection.
 *  -- The specified certRefs[0] is capable of encryption. 
 *
 * Can only be called when no session is active. 
 *
 * Notes:
 * ------
 *
 * -- SSL servers which enforce the SSL3 spec to the letter will
 *    not accept encryption certs with key sizes larger than 512
 *    bits for exportable ciphers. Apps which wish to use encryption 
 *    certs with key sizes larger than 512 bits should disable the 
 *    use of exportable ciphers via the SSLSetEnabledCiphers() call. 
 */
OSStatus
SSLSetEncryptionCertificate	(SSLContextRef		context,
							 CFArrayRef			certRefs);

/*
 * Specify requirements for client-side authentication.
 * Optional; Default is kNeverAuthenticate.
 *
 * Can only be called when no session is active.  
 */
typedef enum {
	kNeverAuthenticate,			/* skip client authentication */
	kAlwaysAuthenticate,		/* require it */
	kTryAuthenticate			/* try to authenticate, but not an error
								 * if client doesn't have a cert */
} SSLAuthenticate;

OSStatus
SSLSetClientSideAuthenticate 	(SSLContextRef		context,
								 SSLAuthenticate	auth);
		
/*
 * Add a DER-encoded dinstiguished name to list of acceptable names
 * to be specified in requests for client certificates. 
 */
OSStatus			
SSLAddDistinguishedName		(SSLContextRef 		context, 
							 const void 		*derDN,
							 size_t 			derDNLen);

/* 
* Add a SecCertificateRef, or a CFArray of them, to a server's list
 * of acceptable Certificate Authorities (CAs) to present to the client
 * when client authentication is performed. 
 *
 * If replaceExisting is true, the specified certificate(s) will replace
 * a possible existing list of acceptable CAs. If replaceExisting is
 * false, the specified certificate(s) will be appended to the existing
 * list of acceptable CAs, if any. 
 *
 * Returns paramErr is this is called on an SSLContextRef which 
 * is configured as a client, or when a session is active. 
 */
OSStatus
SSLSetCertificateAuthorities(SSLContextRef		context,
							 CFTypeRef			certificateOrArray,
							 Boolean 			replaceExisting);

/*
 * Obtain the certificates specified in SSLSetCertificateAuthorities(),
 * if any. Returns a NULL array if SSLSetCertificateAuthorities() has not
 * been called. 
 * Caller must CFRelease the returned array.
 */
OSStatus
SSLCopyCertificateAuthorities(SSLContextRef		context,
							  CFArrayRef		*certificates);	/* RETURNED */
							  
							  
/* 
 * Obtain the list of acceptable distinguished names as provided by 
 * a server (if the SSLContextRef is configured as a client), or as
 * specified by SSLSetCertificateAuthorities() (if the SSLContextRef 
 * is configured as a server). 
 * The returned array contains CFDataRefs, each of which represents 
 * one DER-encoded RDN. This array is suitable for use in 
 * SecIdentitySearchCreateWithAttributes() in order to find
 * a client identity matching a server's requirements. 
 *
 * Caller must CFRelease the returned array. 
 */
OSStatus 
SSLCopyDistinguishedNames	(SSLContextRef		context,
							 CFArrayRef			*names);
							  
							  
/*
 * Obtain client certificate exhange status. Can be called 
 * any time. Reflects the *last* client certificate state change;
 * subsequent to a renegotiation attempt by either peer, the state
 * is reset to kSSLClientCertNone.
 */
OSStatus 
SSLGetClientCertificateState	(SSLContextRef				context,
								 SSLClientCertificateState	*clientState);

/*
 * Specify Diffie-Hellman parameters. Optional; if we are configured to allow
 * for D-H ciphers and a D-H cipher is negotiated, and this function has not
 * been called, a set of process-wide parameters will be calculated. However
 * that can take a long time (30 seconds). 
 */
OSStatus SSLSetDiffieHellmanParams	(SSLContextRef			context,
									 const void 			*dhParams,
									 size_t					dhParamsLen);

/*
 * Return parameter block specified in SSLSetDiffieHellmanParams.
 * Returned data is not copied and belongs to the SSLContextRef.
 */
OSStatus SSLGetDiffieHellmanParams	(SSLContextRef			context,
									 const void 			**dhParams,
									 size_t					*dhParamsLen);
/*
 * Enable/Disable RSA blinding. This feature thwarts a known timing
 * attack to which RSA keys are vulnerable; enabling it is a tradeoff
 * between performance and security. The default for RSA blinding is
 * enabled. 
 */
OSStatus SSLSetRsaBlinding			(SSLContextRef			context,
									 Boolean				blinding);
									 
OSStatus SSLGetRsaBlinding			(SSLContextRef			context,
									 Boolean				*blinding);
									 
/*******************************
 ******** I/O Functions ********
 *******************************/
 
/*
 * Note: depending on the configuration of the underlying I/O 
 * connection, all SSL I/O functions can return errSSLWouldBlock,
 * indicating "not complete, nothing is wrong, except required
 * I/O hasn't completed". Caller may need to repeat I/Os as necessary
 * if the underlying connection has been configured to behave in 
 * a non-blocking manner.
 */
  
/*
 * Perform the SSL handshake. On successful return, session is 
 * ready for normal secure application I/O via SSLWrite and SSLRead.
 *
 * Interesting error returns:
 *
 *	errSSLUnknownRootCert: Peer had a valid cert chain, but the root of 
 *		the chain is unknown. 
 *
 * 	errSSLNoRootCert: Peer had a cert chain which was not verifiable
 *		to a root cert. Handshake was aborted; peer's cert chain
 *		available via SSLGetPeerCertificates().
 *
 * 	errSSLCertExpired: Peer's cert chain had one or more expired certs.
 *
 *  errSSLXCertChainInvalid: Peer had an invalid cert chain (i.e.,
 *		signature verification within the chain failed, or no certs
 *		were found). 
 *
 *  In all of the above errors, the handshake was aborted; the peer's 
 *  cert chain is available via SSLGetPeerCertificates().
 *
 *  Other interesting result codes:
 *
 *  errSSLServerAuthCompleted: Server's cert chain is valid, or was ignored if
 *      cert verification was disabled via SSLSetEnableCertVerify. The client
 *      may decide to continue with the handshake (by calling SSLHandshake
 *      again), or close the connection at this point.
 *
 *  errSSLClientCertRequested: The server has requested a client certificate.
 *      The client may choose to examine the server's certificate and
 *      distinguished name list, then optionally call SSLSetCertificate prior
 *      to resuming the handshake by calling SSLHandshake again.
 *
 * A return value of errSSLWouldBlock indicates that SSLHandshake has to be
 * called again (and again and again until something else is returned).
 */ 	 
OSStatus 
SSLHandshake				(SSLContextRef		context);

/*
 * Normal application-level read/write. On both of these, a errSSLWouldBlock
 * return and a partially completed transfer - or even zero bytes transferred -
 * are NOT mutually exclusive. 
 */
OSStatus 
SSLWrite					(SSLContextRef		context,
							 const void *		data,
							 size_t				dataLength,  // X64 incompatible with impl (UInt32)
							 size_t 			*processed);	/* RETURNED */ 

/*
 * data is mallocd by caller; available size specified in
 * dataLength; actual number of bytes read returned in
 * *processed.
 */
OSStatus 
SSLRead						(SSLContextRef		context,
							 void *				data,			/* RETURNED */
							 size_t				dataLength,
							 size_t 			*processed);	/* RETURNED */ 

/*
 * Determine how much data the client can be guaranteed to 
 * obtain via SSLRead() without blocking or causing any low-level 
 * read operations to occur.
 */
OSStatus 
SSLGetBufferedReadSize		(SSLContextRef context,
							 size_t *bufSize);      			/* RETURNED */

/*
 * Terminate current SSL session. 
 */
OSStatus 
OSStatus 
SSLClose					(SSLContextRef		context);

#ifdef __cplusplus
}
#endif

#endif /* !_SECURITY_SECURETRANSPORT_H_ */
