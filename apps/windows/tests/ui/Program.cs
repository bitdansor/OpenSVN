using OpenSVN.App.Native;
using OpenSVN.App.Services;

var failures = new List<string>();

void Check(string name, bool condition)
{
    if (!condition) failures.Add(name);
}

async Task<OpenSVNException> RunFailureAsync(string identifier)
{
    using var center = new TaskCenter();
    var retryRan = false;
    var failure = new OpenSVNException(identifier, "failed", null, null, "fatal", null, false, false);
    try
    {
        await center.RunAsync<object>(
            "test",
            (_, _) => Task.FromException<object>(failure),
            () =>
            {
                retryRan = true;
                return Task.CompletedTask;
            });
    }
    catch (OpenSVNException exception)
    {
        Check($"{identifier} rethrows the original error", ReferenceEquals(exception, failure));
        var record = center.Tasks[0];
        Check($"{identifier} records failure", record.State == OperationState.Failed);
        Check($"{identifier} keeps state after completion", !record.IsRunning);
        if (identifier == "SVN-0301")
        {
            Check("known safe failure keeps retry", record.IsRetryVisible);
        }
        else
        {
            Check($"{identifier} hides uncertain retry", !record.IsRetryVisible);
            Check($"{identifier} clears uncertain action", record.RetryAction is null);
        }
        Check($"{identifier} does not execute retry automatically", !retryRan);
        return exception;
    }
    throw new InvalidOperationException("expected the operation to fail");
}

await RunFailureAsync("SVN-0301");
await RunFailureAsync("SVN-0401");
await RunFailureAsync("SVN-0201");
await RunFailureAsync("SVN-0402");
await RunFailureAsync("SVN-9002");
await RunFailureAsync("SVN-9998");
await RunFailureAsync("SVN-9999");

using (var center = new TaskCenter())
{
    var record = new TaskRecord("manual") { RetryAction = () => Task.CompletedTask };
    record.State = OperationState.Failed;
    Check("manual failure shows retry", record.IsRetryVisible);
    record.RetryAction = null;
    Check("clearing the action hides retry", !record.IsRetryVisible);
}

using (var center = new TaskCenter())
{
    var result = await center.RunAsync(
        "success",
        (_, _) => Task.FromResult(42),
        successDetail: "done");
    var record = center.Tasks[0];
    Check("success returns the value", result == 42);
    Check("success records completion", record.State == OperationState.Succeeded);
    Check("success has no retry", !record.IsRetryVisible);
}

if (failures.Count > 0)
{
    foreach (var failure in failures) Console.Error.WriteLine("FAIL: " + failure);
    return 1;
}

Console.WriteLine("Managed UI state tests passed.");
return 0;
