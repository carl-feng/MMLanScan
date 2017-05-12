//
//  netbiosHeader.h
//  test
//
//  Created by Thinh Nguyen Duc on 4/15/17.
//  Copyright © 2017 trekvn. All rights reserved.
//

#ifndef netbiosHeader_h
#define netbiosHeader_h

#import "netbios_defs.h"
#import "netbiosNS.h"
#import "netbiosQuery.h"
#import "netbiosSession.h"
#import "netbiosUtils.h"

#define HAVE_PIPE 1
#define HAVE_SYS_SOCKET_H 1
#define HAVE_ARPA_INET_H 1

#define DSM_SUCCESS         (0)
#define DSM_ERROR_GENERIC   (-1)
#define DSM_ERROR_NT        (-2) /* see smb_session_get_nt_status */
#define DSM_ERROR_NETWORK   (-3)
#define DSM_ERROR_CHARSET   (-4)

#endif /* netbiosHeader_h */
