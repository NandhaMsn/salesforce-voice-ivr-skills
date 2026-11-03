# IVR Apex invocable template

```apex
public with sharing class IvrExampleService {
    public class Request {
        @InvocableVariable(required=true) public String operation;
        @InvocableVariable public String accountNumber;
        @InvocableVariable public String zipCode;
    }
    public class Result {
        @InvocableVariable public String error;    // NO_ERROR on success
        @InvocableVariable public String speech;   // text the flow plays
    }

    @InvocableMethod(label='IVR: Example Operation' callout=true)
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            try {
                // 1. validate input (return MISSING_REQUIRED_FIELDS / NOT_FOUND, don't throw)
                // 2. match exactly one customer on several factors
                // 3. call the back end through a Named/External Credential
                // 4. map the response to speech text
                res.error = 'NO_ERROR';
            } catch (Exception e) {
                res.error = 'SYSTEM_ERROR';         // never log caller data
            }
            results.add(res);
        }
        return results;
    }
}
```

## Tests
- Mock callouts with `HttpCalloutMock`; cover success, each error code and an exception.
- Use synthetic data only (e.g. phone 2025550100, account 0000000001).
- Where the platform blocks DML on an object in tests (e.g. `VoiceCallRecording`), inject values through a `@TestVisible` static map and assert on a `@TestVisible` result list.
