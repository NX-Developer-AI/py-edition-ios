#import <QuartzCore/QuartzCore.h>
#import "ServerStatusViewController.h"
#import "utils.h"

#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>

static NSString *const ServerHistoryKey = @"pyedition.server.history";
static const int ServerDefaultPort = 25565;
static const int ServerTimeoutSeconds = 10;

typedef NS_ENUM(NSInteger, ServerStatusSection) {
    ServerStatusSectionInput,
    ServerStatusSectionResult,
    ServerStatusSectionHistory,
    ServerStatusSectionCount
};

static int ServerConnect(const char *host, int port) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char portText[8];
    snprintf(portText, sizeof(portText), "%d", port);
    struct addrinfo *result = NULL;
    if (getaddrinfo(host, portText, &hints, &result) != 0) {
        return -2;
    }
    int descriptor = -1;
    for (struct addrinfo *entry = result; entry != NULL; entry = entry->ai_next) {
        descriptor = socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
        if (descriptor < 0) {
            continue;
        }
        struct timeval timeout = {ServerTimeoutSeconds, 0};
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        int noSignalPipe = 1;
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignalPipe, sizeof(noSignalPipe));
        if (connect(descriptor, entry->ai_addr, entry->ai_addrlen) == 0) {
            break;
        }
        close(descriptor);
        descriptor = -1;
    }
    freeaddrinfo(result);
    return descriptor;
}

static void ServerAppendVarInt(NSMutableData *data, int value) {
    uint32_t remaining = (uint32_t)value;
    do {
        uint8_t byte = remaining & 0x7F;
        remaining >>= 7;
        if (remaining != 0) {
            byte |= 0x80;
        }
        [data appendBytes:&byte length:1];
    } while (remaining != 0);
}

static void ServerAppendString(NSMutableData *data, NSString *text) {
    NSData *encoded = [text dataUsingEncoding:NSUTF8StringEncoding];
    ServerAppendVarInt(data, (int)encoded.length);
    [data appendData:encoded];
}

static NSData *ServerPacket(int identifier, NSData *payload) {
    NSMutableData *body = [NSMutableData data];
    ServerAppendVarInt(body, identifier);
    [body appendData:payload];
    NSMutableData *packet = [NSMutableData data];
    ServerAppendVarInt(packet, (int)body.length);
    [packet appendData:body];
    return packet;
}

static BOOL ServerSendAll(int descriptor, NSData *data) {
    const uint8_t *bytes = data.bytes;
    size_t sent = 0;
    while (sent < data.length) {
        ssize_t written = send(descriptor, bytes + sent, data.length - sent, 0);
        if (written <= 0) {
            return NO;
        }
        sent += (size_t)written;
    }
    return YES;
}

static BOOL ServerReadExactly(int descriptor, uint8_t *buffer, size_t count) {
    size_t received = 0;
    while (received < count) {
        ssize_t got = recv(descriptor, buffer + received, count - received, 0);
        if (got <= 0) {
            return NO;
        }
        received += (size_t)got;
    }
    return YES;
}

static BOOL ServerReadVarInt(int descriptor, int *value) {
    int result = 0;
    for (int shift = 0; shift < 35; shift += 7) {
        uint8_t byte;
        if (!ServerReadExactly(descriptor, &byte, 1)) {
            return NO;
        }
        result |= (byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) {
            *value = result;
            return YES;
        }
    }
    return NO;
}

static BOOL ServerDecodeVarInt(const uint8_t *bytes, NSUInteger length, NSUInteger *position, int *value) {
    int result = 0;
    for (int shift = 0; shift < 35; shift += 7) {
        if (*position >= length) {
            return NO;
        }
        uint8_t byte = bytes[(*position)++];
        result |= (byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) {
            *value = result;
            return YES;
        }
    }
    return NO;
}

static NSString *ServerPlainText(id component) {
    NSMutableString *output = [NSMutableString string];
    if ([component isKindOfClass:NSString.class]) {
        [output appendString:component];
    } else if ([component isKindOfClass:NSArray.class]) {
        for (id part in component) {
            [output appendString:ServerPlainText(part)];
        }
    } else if ([component isKindOfClass:NSDictionary.class]) {
        id text = component[@"text"] ?: component[@"translate"];
        if ([text isKindOfClass:NSString.class]) {
            [output appendString:text];
        }
        id extra = component[@"extra"];
        if (extra != nil) {
            [output appendString:ServerPlainText(extra)];
        }
    } else if ([component isKindOfClass:NSNumber.class]) {
        [output appendString:[component stringValue]];
    }
    NSRegularExpression *formatting = [NSRegularExpression regularExpressionWithPattern:@"§." options:0 error:nil];
    return [formatting stringByReplacingMatchesInString:output options:0 range:NSMakeRange(0, output.length) withTemplate:@""];
}

static NSDictionary *ServerPing(NSString *host, int port, NSString **errorKey) {
    int descriptor = ServerConnect(host.UTF8String, port);
    if (descriptor == -2) {
        *errorKey = @"pyedition.server.error.resolve";
        return nil;
    }
    if (descriptor < 0) {
        *errorKey = @"pyedition.server.error.connect";
        return nil;
    }
    NSMutableData *handshake = [NSMutableData data];
    ServerAppendVarInt(handshake, -1);
    ServerAppendString(handshake, host);
    uint8_t portBytes[2] = {(uint8_t)(port >> 8), (uint8_t)(port & 0xFF)};
    [handshake appendBytes:portBytes length:2];
    ServerAppendVarInt(handshake, 1);
    NSMutableData *request = [NSMutableData dataWithData:ServerPacket(0x00, handshake)];
    [request appendData:ServerPacket(0x00, [NSData data])];

    NSDictionary *result = nil;
    int length = 0;
    if (ServerSendAll(descriptor, request) && ServerReadVarInt(descriptor, &length) && length > 0 && length < 4 * 1024 * 1024) {
        NSMutableData *body = [NSMutableData dataWithLength:(NSUInteger)length];
        if (ServerReadExactly(descriptor, body.mutableBytes, (size_t)length)) {
            NSUInteger position = 0;
            int identifier = -1;
            int jsonLength = 0;
            const uint8_t *bytes = body.bytes;
            if (ServerDecodeVarInt(bytes, body.length, &position, &identifier) && identifier == 0 &&
                ServerDecodeVarInt(bytes, body.length, &position, &jsonLength) && position + (NSUInteger)jsonLength <= body.length) {
                NSData *json = [body subdataWithRange:NSMakeRange(position, (NSUInteger)jsonLength)];
                id parsed = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
                if ([parsed isKindOfClass:NSDictionary.class]) {
                    NSMutableDictionary *status = [parsed mutableCopy];
                    NSDate *sentAt = [NSDate date];
                    int64_t timestamp = (int64_t)(sentAt.timeIntervalSince1970 * 1000);
                    uint8_t pingPayload[8];
                    for (int index = 0; index < 8; index++) {
                        pingPayload[index] = (uint8_t)(timestamp >> ((7 - index) * 8));
                    }
                    int pongLength = 0;
                    if (ServerSendAll(descriptor, ServerPacket(0x01, [NSData dataWithBytes:pingPayload length:8])) &&
                        ServerReadVarInt(descriptor, &pongLength) && pongLength > 0 && pongLength < 64) {
                        uint8_t pong[64];
                        if (ServerReadExactly(descriptor, pong, (size_t)pongLength)) {
                            status[@"latency"] = @((NSInteger)([[NSDate date] timeIntervalSinceDate:sentAt] * 1000));
                        }
                    }
                    result = status;
                }
            }
        }
    }
    close(descriptor);
    if (result == nil) {
        *errorKey = @"pyedition.server.error.response";
    }
    return result;
}

@interface ServerStatusViewController () <UITextFieldDelegate>
@property(nonatomic) UITextField *addressField;
@property(nonatomic) NSArray<NSArray<NSString *> *> *rows;
@property(nonatomic) UIImage *favicon;
@property(nonatomic) NSString *errorMessage;
@property(nonatomic) BOOL loading;
@property(nonatomic) NSArray<NSString *> *history;
@end

@implementation ServerStatusViewController

- (id)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.title = localize(@"pyedition.server.title", nil);
    return self;
}

- (NSString *)imageName {
    return @"antenna.radiowaves.left.and.right";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.history = [NSUserDefaults.standardUserDefaults stringArrayForKey:ServerHistoryKey] ?: @[];
    self.rows = @[];
    self.addressField = [[UITextField alloc] init];
    self.addressField.placeholder = @"play.example.net:25565";
    self.addressField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.addressField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.addressField.keyboardType = UIKeyboardTypeURL;
    self.addressField.returnKeyType = UIReturnKeyGo;
    self.addressField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.addressField.delegate = self;
    self.addressField.translatesAutoresizingMaskIntoConstraints = NO;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    [self checkServer];
    return YES;
}

- (void)checkServer {
    NSString *address = [self.addressField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (address.length == 0 || self.loading) {
        return;
    }
    NSString *host = address;
    int port = ServerDefaultPort;
    NSRange colon = [address rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location != NSNotFound && [address componentsSeparatedByString:@":"].count == 2) {
        host = [address substringToIndex:colon.location];
        port = [[address substringFromIndex:colon.location + 1] intValue];
        if (port <= 0 || port > 65535) {
            port = ServerDefaultPort;
        }
    }
    self.loading = YES;
    self.errorMessage = nil;
    [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *errorKey = nil;
        NSDictionary *status = ServerPing(host, port, &errorKey);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loading = NO;
            if (status == nil) {
                self.rows = @[];
                self.favicon = nil;
                self.errorMessage = localize(errorKey, nil);
            } else {
                [self showStatus:status host:host port:port];
                [self remember:address];
            }
            [self.tableView reloadData];
        });
    });
}

- (void)showStatus:(NSDictionary *)status host:(NSString *)host port:(int)port {
    NSDictionary *version = [status[@"version"] isKindOfClass:NSDictionary.class] ? status[@"version"] : @{};
    NSDictionary *players = [status[@"players"] isKindOfClass:NSDictionary.class] ? status[@"players"] : @{};
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObject:@[localize(@"pyedition.server.address", nil), [NSString stringWithFormat:@"%@:%d", host, port]]];
    [rows addObject:@[localize(@"pyedition.server.version", nil), ServerPlainText(version[@"name"] ?: @"")]];
    [rows addObject:@[localize(@"pyedition.server.protocol", nil), [NSString stringWithFormat:@"%@", version[@"protocol"] ?: @"-"]]];
    [rows addObject:@[localize(@"pyedition.server.players", nil), [NSString stringWithFormat:@"%@ / %@", players[@"online"] ?: @0, players[@"max"] ?: @0]]];
    [rows addObject:@[localize(@"pyedition.server.latency", nil), status[@"latency"] ? [NSString stringWithFormat:@"%@ ms", status[@"latency"]] : @"-"]];
    NSArray *sample = [players[@"sample"] isKindOfClass:NSArray.class] ? players[@"sample"] : @[];
    if (sample.count > 0) {
        NSMutableArray *names = [NSMutableArray array];
        for (NSDictionary *entry in sample) {
            if ([entry isKindOfClass:NSDictionary.class] && entry[@"name"]) {
                [names addObject:ServerPlainText(entry[@"name"])];
            }
        }
        [rows addObject:@[localize(@"pyedition.server.online", nil), [names componentsJoinedByString:@", "]]];
    }
    [rows addObject:@[localize(@"pyedition.server.motd", nil), ServerPlainText(status[@"description"] ?: @"")]];
    self.rows = rows;
    self.favicon = nil;
    NSString *favicon = status[@"favicon"];
    if ([favicon isKindOfClass:NSString.class]) {
        NSRange comma = [favicon rangeOfString:@","];
        if (comma.location != NSNotFound) {
            NSData *data = [[NSData alloc] initWithBase64EncodedString:[favicon substringFromIndex:comma.location + 1] options:NSDataBase64DecodingIgnoreUnknownCharacters];
            self.favicon = data ? [UIImage imageWithData:data] : nil;
        }
    }
}

- (void)remember:(NSString *)address {
    NSMutableArray *history = [self.history mutableCopy];
    [history removeObject:address];
    [history insertObject:address atIndex:0];
    while (history.count > 10) {
        [history removeLastObject];
    }
    self.history = history;
    [NSUserDefaults.standardUserDefaults setObject:history forKey:ServerHistoryKey];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ServerStatusSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case ServerStatusSectionInput:
            return 2;
        case ServerStatusSectionResult:
            return self.errorMessage ? 1 : (NSInteger)self.rows.count;
        case ServerStatusSectionHistory:
            return (NSInteger)self.history.count;
        default:
            return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == ServerStatusSectionHistory && self.history.count > 0) {
        return localize(@"pyedition.server.history", nil);
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ServerStatusSectionInput && indexPath.row == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        [self.addressField removeFromSuperview];
        [cell.contentView addSubview:self.addressField];
        [NSLayoutConstraint activateConstraints:@[
            [self.addressField.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [self.addressField.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [self.addressField.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
            [self.addressField.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
            [self.addressField.heightAnchor constraintGreaterThanOrEqualToConstant:30]
        ]];
        return cell;
    }
    if (indexPath.section == ServerStatusSectionInput) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = localize(@"pyedition.server.check", nil);
        cell.textLabel.textColor = self.view.tintColor;
        if (self.loading) {
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [spinner startAnimating];
            cell.accessoryView = spinner;
        }
        return cell;
    }
    if (indexPath.section == ServerStatusSectionResult) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (self.errorMessage) {
            cell.textLabel.text = self.errorMessage;
            cell.textLabel.textColor = UIColor.systemRedColor;
            cell.textLabel.numberOfLines = 0;
            return cell;
        }
        NSArray<NSString *> *row = self.rows[indexPath.row];
        cell.textLabel.text = row[0];
        cell.detailTextLabel.text = row[1];
        cell.detailTextLabel.numberOfLines = 0;
        if (indexPath.row == 0 && self.favicon) {
            cell.imageView.image = self.favicon;
            cell.imageView.layer.magnificationFilter = kCAFilterNearest;
        }
        return cell;
    }
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = self.history[indexPath.row];
    cell.textLabel.textColor = self.view.tintColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == ServerStatusSectionInput && indexPath.row == 1) {
        [self.addressField resignFirstResponder];
        [self checkServer];
    } else if (indexPath.section == ServerStatusSectionHistory) {
        self.addressField.text = self.history[indexPath.row];
        [self checkServer];
    } else if (indexPath.section == ServerStatusSectionResult && !self.errorMessage) {
        UIPasteboard.generalPasteboard.string = self.rows[indexPath.row][1];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == ServerStatusSectionHistory;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) {
        return;
    }
    NSMutableArray *history = [self.history mutableCopy];
    [history removeObjectAtIndex:indexPath.row];
    self.history = history;
    [NSUserDefaults.standardUserDefaults setObject:history forKey:ServerHistoryKey];
    [tableView reloadData];
}

@end
