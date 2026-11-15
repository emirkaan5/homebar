# SmartRent protocol notes

Sources: the open-source smartrent-py library (used as a reference only, not as
a dependency). **Verify every item marked "check" in Phase 0** by recording the
resident web dashboard in your browser's developer tools, as the plan describes.

## REST (base `https://control.smartrent.com/api/v2/`)

| Call | Request | Reply | Status |
|---|---|---|---|
| Sign in | `POST sessions` `{"email","password"}` | `access_token`, `refresh_token`, `expires` (may be inside `data`) | from smartrent-py |
| 2FA | Reply has `tfa_api_token` → `POST sessions` `{"tfa_api_token","token": <code>}` | tokens | from smartrent-py |
| Refresh | `POST tokens`, header `authorization-x-refresh: <refresh_token>` | tokens | from smartrent-py |
| Hubs | `GET hubs`, `Authorization: Bearer <token>` | list of hubs | check: field for the unit name |
| Devices | `GET hubs/{id}/devices` | list of devices with `id`, `type`, `name`, `attributes[]` | check: attribute value key (`state`?) |

Errors: `{"errors": [...]}`. Check the exact shape.

## Websocket

`wss://control.smartrent.com/socket/websocket?token=<access_token>&vsn=2.0.0`

Phoenix channels v2: each message is `[join_ref, ref, topic, event, payload]`.

| Message | Format | Status |
|---|---|---|
| Join | topic `devices:<device_id>`, event `phx_join`, payload `{}` | from smartrent-py |
| Heartbeat | topic `phoenix`, event `heartbeat`, every 30 s | Phoenix standard; check |
| Update in | payload `{"name", "last_read_state", "type", "device_id"}` | check: event name |
| Command out | event `update_attributes`, payload `{"device_id": 42, "attributes": [{"name", "value"}]}` | from smartrent-py |

## Thermostat attributes

`current_temp`, `current_humidity`, `heating_setpoint`, `cooling_setpoint`,
`mode` (`heat`, `cool`, `auto`, `off`, `aux_heat`), `fan_mode` (`auto`, `on`),
`operating_state`. All values travel as strings. Check the `operating_state` values.

## Where the code handles each item

- Field names and fallbacks: `Sources/SmartRentProvider/DeviceMapper.swift`
- Login, refresh, errors: `Sources/SmartRentProvider/SmartRentAPI.swift`
- Websocket: `Sources/SmartRentProvider/PhoenixSocket.swift`

After you record real messages, put redacted copies in `Tests/HomeBarTests/Fixtures`
and add tests for them.

# Philips Hue (API v2, local)

Tested only against fixtures and fake lights so far. Check these against a real bridge.

| Call | Request | Reply |
|---|---|---|
| Find | Bonjour `_hue._tcp`; TXT `bridgeid` | service name, then IPv4 by connecting |
| Pair | `POST https://<ip>/api` `{"devicetype":"homebar#mac","generateclientkey":true}` | `[{"success":{"username":<key>}}]` or `[{"error":{"type":101}}]` until the button is pressed |
| Name | `GET https://<ip>/api/0/config` (no key) | `name`, `bridgeid` |
| Lights | `GET /clip/v2/resource/light`, header `hue-application-key` | `data[]`: `id`, `metadata.name`, `on.on`, `dimming.brightness`, `color_temperature.{mirek,mirek_valid,mirek_schema}`, `color.xy` |
| Change | `PUT /clip/v2/resource/light/<id>` `{"on":{"on":true},"dimming":{"brightness":50}}` | `{"data":[…],"errors":[]}` |
| Live | `GET /eventstream/clip/v2`, `Accept: text/event-stream` | `data: [{"type":"update","data":[{"id","type":"light",…changed fields}]}]` |

Brightness and colour temperature are throttled to one command per 150 ms during a drag
(Hue asks for no more than about 10 commands a second per light).

# Amazon smart plugs (private Alexa API, cloud)

Unofficial and unverified: nothing here has been tested against a real account. The app
only ever sends the session cookies that Amazon's own sign-in page left behind; the
password and the one-time code stay in that page.

Amazon answers at the Alexa address of the marketplace the account belongs to:
`amazon.com` → `alexa.amazon.com`, and likewise for the others
(`alexa.amazon.co.uk`, `alexa.amazon.de`, …).

| Call | Request | Reply | Status |
|---|---|---|---|
| Entities | `GET https://alexa.<tld>/api/behaviors/entities?skillId=amzn1.ask.1p.smarthome` | `entityId`, `entityType`, `friendlyName`; the appliance id also under `legacyAppliance.applianceId` | check: whether the reply is always a bare list, and whether `legacyAppliance` is always there |
| State | `POST /api/phoenix/state` `{"stateRequests":[{"entityId","entityType":"APPLIANCE"}]}` | `deviceStates[]`, each with `capabilityStates[]`. A capability is an object in some replies and a string holding JSON in others: `{"namespace":"Alexa.PowerController","name":"powerState","value":"ON"}` | check |
| Change | `PUT /api/phoenix/state` `{"controlRequests":[{"entityId","entityType":"APPLIANCE","parameters":{"action":"turnOn"}}]}` | empty body; `turnOff` likewise | check |

Headers: `Cookie: csrf=<token>; session-id=<id>`, plus `csrf: <token>`, with the Alexa
address as `Referer` and `Origin`.

There is no push. The app reads the state on a timer (20 s) and, after a change, reads it
back until the new value appears (up to 6 s, 700 ms apart). Polling is what gets these
sessions limited or flagged, so do not shorten the interval.

An Amazon plug is a switch: on and off only, no brightness and no colour
(`DeviceKind.plug`). The plug must be set up in the Alexa app once before it appears here.

| Where | What |
|---|---|
| `Sources/AmazonProvider/AmazonAPI.swift` | Session, marketplace, addresses, the requests themselves |
| `Sources/AmazonProvider/AmazonMapper.swift` | Field names, fallbacks, and the request bodies |
| `Sources/AmazonProvider/AmazonProvider.swift` | Polling, change confirmation, and the stream |
| `Sources/UI/AmazonSetupView.swift` | The sign-in page and the cookies it leaves behind |
