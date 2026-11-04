# IVR Apex invocable template

A shared, client-neutral service. Names are placeholders. Security rules: `security.md` §6.

```apex
public with sharing class ExampleLookupService {
    // Named Credential per back end; per-client differences live in IVR_Client_Config__mdt, never in code.
    private static final String NAMED_CREDENTIAL = 'callout:IVR_Backend';
    private static final Integer TIMEOUT_MS = 8000;

    public class Request {
        @InvocableVariable(required=true) public String clientKey;   // scopes config and queries
        @InvocableVariable(required=true) public String operation;   // e.g. 'amountDue'
        @InvocableVariable public String factorA;                    // caller-typed digits
        @InvocableVariable public String factorB;
    }
    public class Result {
        @InvocableVariable public String errorCode;   // OK on success
        @InvocableVariable public String speech;      // text the flow plays; no data the caller didn't need
    }

    @InvocableMethod(label='Voice: Look up amount due' callout=true)
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(handle(req));
        }
        return results;
    }

    private static Result handle(Request req) {
        Result res = new Result();
        try {
            IVR_Client_Config__mdt cfg = IVR_Client_Config__mdt.getInstance(req.clientKey);
            if (cfg == null) { res.errorCode = 'UNKNOWN_CLIENT'; return res; }          // never fall back
            if (!isDigits(req.factorA, 10, 10) || !isDigits(req.factorB, 5, 5)) {   // account no., ZIP
                res.errorCode = 'INVALID_INPUT'; return res;                           // reject, don't coerce
            }

            HttpRequest http = new HttpRequest();
            http.setEndpoint(NAMED_CREDENTIAL + '/v1/' + EncodingUtil.urlEncode(req.operation, 'UTF-8'));
            http.setMethod('POST');
            http.setTimeout(TIMEOUT_MS);
            http.setHeader('Content-Type', 'application/json');
            http.setBody(JSON.serialize(new Map<String, Object>{
                'client' => cfg.Backend_Client_Code__c, 'a' => req.factorA, 'b' => req.factorB }));
            HttpResponse resp = new Http().send(http);

            if (resp.getStatusCode() == 404) { res.errorCode = 'NOT_FOUND'; return res; }
            if (resp.getStatusCode() != 200) { res.errorCode = 'BACKEND_ERROR'; return res; }
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
            res.speech = toSpeech(body);                 // null-safe, length-limited
            res.errorCode = 'OK';
        } catch (Exception e) {
            res.errorCode = 'SYSTEM_ERROR';              // no e.getMessage() to the flow, no logging of inputs
        }
        return res;
    }

    private static Boolean isDigits(String s, Integer minLen, Integer maxLen) {
        return s != null && s.isNumeric() && s.length() >= minLen && s.length() <= maxLen;
    }

    private static String toSpeech(Map<String, Object> body) {
        Object v = body == null ? null : body.get('value');
        String text = v == null ? '' : String.valueOf(v);
        return text.left(300);                          // back-end data is untrusted: cap what gets spoken
    }
}
```

Records instead of callouts: query with bind variables only, always filtered by client:
```apex
List<Account> matches = [SELECT Id FROM Account
                         WHERE IVR_Client__c = :req.clientKey AND Account_Number__c = :req.factorA LIMIT 2];
if (matches.size() != 1) { res.errorCode = 'NOT_FOUND'; return res; }   // exactly one match or nothing
```

## Tests
- Mock callouts with `HttpCalloutMock`; cover success, each error code, a timeout/exception, invalid input and an unknown client key.
- Synthetic data only (phone 2025550100, account 0000000001, ZIP 00000).
- Multi-client: two synthetic client keys with the same number; an operation for one client never reads or changes the other's records.
- Where the platform blocks DML on an object in tests (e.g. `VoiceCallRecording`), inject values through a `@TestVisible` static map and assert on a `@TestVisible` result list.
- Assert that no `System.debug` output contains the inputs (or simply don't debug inputs).
