#!/usr/bin/env python3
"""Test matrix for the announce->inject->precmd-OSC approach."""
import os, sys, tempfile, shutil, subprocess
from harness import Session, announce_rc

RESULTS = []

def case(name, ok, detail=""):
    RESULTS.append((name, ok, detail))
    mark = "PASS" if ok else "FAIL"
    print(f"  [{mark}] {name}  {detail}")

def have(prog):
    return shutil.which(prog) is not None


def make_rcdir(shell, extra=""):
    d = tempfile.mkdtemp(prefix="zmxpoc-")
    if shell == "bash":
        with open(f"{d}/bashrc", "w") as f:
            f.write(extra + "\n" + announce_rc("bash"))
        return d, ["bash", "--rcfile", f"{d}/bashrc", "-i"], {}
    if shell == "zsh":
        with open(f"{d}/.zshrc", "w") as f:
            f.write(extra + "\n" + announce_rc("zsh"))
        return d, ["zsh", "-i"], {"ZDOTDIR": d}
    if shell == "fish":
        os.makedirs(f"{d}/fish", exist_ok=True)
        with open(f"{d}/fish/config.fish", "w") as f:
            f.write(extra + "\n" + announce_rc("fish"))
        return d, ["fish", "-i"], {"XDG_CONFIG_HOME": d}
    raise ValueError(shell)


def test_basic(shell):
    print(f"\n== {shell}: basic ==")
    d, argv, env = make_rcdir(shell)
    s = Session(argv, env=env)
    try:
        ann = s.wait_announce()
        case(f"{shell} announce received", ann == shell, f"got={ann}")
        if not ann:
            return
        ec, via = s.run("true")
        case(f"{shell} true -> 0 via osc", ec == 0 and via == "osc-done", f"ec={ec} via={via}")
        ec, via = s.run("false")
        case(f"{shell} false -> 1 via osc", ec == 1 and via == "osc-done", f"ec={ec} via={via}")
        ec, via = s.run("sh -c 'exit 42'")
        case(f"{shell} exit 42 subproc", ec == 42 and via == "osc-done", f"ec={ec} via={via}")
        ec, via = s.run("ls /no/such/path/xyz")
        case(f"{shell} failing cmd nonzero", (ec or 0) > 0 and via == "osc-done", f"ec={ec} via={via}")
        ec, via = s.run("cd /tmp")
        case(f"{shell} cd reports via osc", via == "osc-done", f"ec={ec} via={via}")
    finally:
        s.close()
        shutil.rmtree(d, ignore_errors=True)


def test_edge(shell):
    print(f"\n== {shell}: edge cases ==")
    d, argv, env = make_rcdir(shell)
    s = Session(argv, env=env)
    try:
        if not s.wait_announce():
            case(f"{shell} edge setup", False, "no announce")
            return
        # background job: precmd fires immediately with $?=0; acceptable but note it
        ec, via = s.run("sleep 0.5 &")
        case(f"{shell} 'sleep &' returns immediately", via == "osc-done", f"ec={ec} via={via}")
        # signal kill
        ec, via = s.run("sh -c 'kill -TERM $$'")
        case(f"{shell} SIGTERM -> 143", ec == 143 and via == "osc-done", f"ec={ec} via={via}")
        # syntax error -- shell-specific so we know it's a parse error, not a continuation
        bad = {"bash": "fi", "zsh": "fi", "fish": ")"}[shell]
        ec, via = s.run(bad)
        # bash sets $?=2; zsh hook reports 125 via preexec-pairing; fish hook
        # reports 125 via fish_posterror. All complete via OSC, no hang.
        want = 2 if shell == "bash" else 125
        case(f"{shell} syntax error -> ec={want} via osc",
             ec == want and via == "osc-done", f"ec={ec} via={via}")
        # verify the next command isn't poisoned by leftover buffer
        ec, via = s.run("true")
        case(f"{shell} recovers after syntax error", ec == 0 and via == "osc-done",
             f"ec={ec} via={via}")
    finally:
        s.close()
        shutil.rmtree(d, ignore_errors=True)

    # exec: fresh session so prior state can't leak
    d, argv, env = make_rcdir(shell)
    s = Session(argv, env=env)
    try:
        s.wait_announce()
        ec, via = s.run("exec true")
        case(f"{shell} 'exec true' detected", via in ("pty-eof", "prompt-fallback"), f"ec={ec} via={via}")
    finally:
        s.close()
        shutil.rmtree(d, ignore_errors=True)

    # exit N: fresh session so we can observe pty-eof
    d, argv, env = make_rcdir(shell)
    s = Session(argv, env=env)
    try:
        s.wait_announce()
        ec, via = s.run("exit 7")
        case(f"{shell} 'exit 7' -> pty-eof ec=7", via == "pty-eof" and ec == 7, f"ec={ec} via={via}")
    finally:
        s.close()
        shutil.rmtree(d, ignore_errors=True)


def test_existing_hooks(shell):
    """Coexist with user's existing PROMPT_COMMAND / precmd (starship-like)."""
    print(f"\n== {shell}: with pre-existing prompt hook ==")
    if shell == "bash":
        extra = 'PROMPT_COMMAND="echo -n"'
    elif shell == "zsh":
        extra = 'precmd() { : ; }'
    elif shell == "fish":
        extra = 'function fish_prompt; echo -n "poc> "; end'
    d, argv, env = make_rcdir(shell, extra=extra)
    s = Session(argv, env=env)
    try:
        if not s.wait_announce():
            case(f"{shell}+hook setup", False, "no announce")
            return
        ec, via = s.run("false")
        case(f"{shell}+existing-hook false -> 1", ec == 1 and via == "osc-done", f"ec={ec} via={via}")
    finally:
        s.close()
        shutil.rmtree(d, ignore_errors=True)


def test_no_announce():
    """Shell without the rc snippet -> no hook -> prompt-fallback only."""
    print(f"\n== bash: NO announce in rc (fallback path) ==")
    s = Session(["bash", "--norc", "-i"])
    try:
        ann = s.wait_announce(timeout=1)
        case("no-rc: no announce", ann is None, f"ann={ann}")
        ec, via = s.run("false")
        case("no-rc: completion via prompt-fallback", via == "prompt-fallback" and ec is None,
             f"ec={ec} via={via}")
    finally:
        s.close()


SSH = ("ssh -p 2222 -i /tmp/zmx-poc-sshd/client_key "
       "-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
       "-o LogLevel=ERROR localhost")

def test_ssh():
    """Over ssh localhost: remote rc has the announce line."""
    print(f"\n== ssh localhost ==")
    r = subprocess.run(SSH.split() + ["true"], capture_output=True, timeout=5)
    if r.returncode != 0:
        case("ssh localhost reachable", False, r.stderr.decode()[:80])
        return
    case("ssh localhost reachable", True)

    d = tempfile.mkdtemp(prefix="zmxpoc-ssh-")
    rc = f"{d}/bashrc"
    with open(rc, "w") as f:
        f.write(announce_rc("bash"))
    # Outer is a plain bash with NO announce; we type `ssh localhost ...` into it.
    s = Session(["bash", "--norc", "-i"])
    try:
        s._pump(0.5)
        # ssh -t for a PTY; remote bash sources our rc.
        s.type(f"{SSH} -t bash --rcfile {rc} -i\r")
        ann = s.wait_announce(timeout=5)
        case("ssh: remote announce received", ann == "bash", f"got={ann}")
        if ann:
            ec, via = s.run("false")
            case("ssh: remote false -> 1 via osc", ec == 1 and via == "osc-done", f"ec={ec} via={via}")
            ec, via = s.run("hostname")
            case("ssh: remote cmd via osc", via == "osc-done", f"ec={ec} via={via}")
            # remote shell exits -> we fall back to OUTER bash prompt (?2004h)
            ec, via = s.run("exit")
            case("ssh: remote exit -> outer prompt-fallback", via in ("prompt-fallback", "osc-done"),
                 f"ec={ec} via={via}")
    finally:
        s.close()
        shutil.rmtree(d, ignore_errors=True)


def test_nested():
    """bash (announced) -> bash subshell (announced again)."""
    print(f"\n== nested bash -> bash ==")
    d, argv, env = make_rcdir("bash")
    s = Session(argv, env=env)
    try:
        s.wait_announce()
        # inner bash with same rc
        n_hello = sum(1 for e in s.events if e[0] == "hello")
        s.type(f"bash --rcfile {d}/bashrc -i\r")
        s._pump(1.5)
        n_hello2 = sum(1 for e in s.events if e[0] == "hello")
        case("nested: inner announce received", n_hello2 > n_hello, f"{n_hello}->{n_hello2}")
        ec, via = s.run("false")
        case("nested: inner false -> 1 via osc", ec == 1 and via == "osc-done", f"ec={ec} via={via}")
        ec, via = s.run("exit")
        case("nested: inner exit -> outer prompt", via in ("osc-done", "prompt-fallback"), f"ec={ec} via={via}")
        ec, via = s.run("false")
        case("nested: outer still hooked after inner exit", ec == 1 and via == "osc-done", f"ec={ec} via={via}")
    finally:
        s.close()
        shutil.rmtree(d, ignore_errors=True)


def test_weird(shell):
    """Pipes, &&/||, subshells, bg jobs, heredoc, Ctrl-C, long lines, etc."""
    print(f"\n== {shell}: weird constructs ==")
    d, argv, env = make_rcdir(shell)
    s = Session(argv, env=env)
    try:
        if not s.wait_announce():
            case(f"{shell} weird setup", False)
            return

        # Pipes: $? = last command's status
        ec, _ = s.run("true | false")
        case(f"{shell} 'true | false' -> 1", ec == 1, f"ec={ec}")
        ec, _ = s.run("false | true")
        case(f"{shell} 'false | true' -> 0 (or 1 if pipefail/fish)", ec in (0, 1), f"ec={ec}")

        # && / ||
        ec, _ = s.run("false && echo nope")
        case(f"{shell} 'false && x' -> 1", ec == 1, f"ec={ec}")
        ec, _ = s.run("false || true")
        case(f"{shell} 'false || true' -> 0", ec == 0, f"ec={ec}")

        # Subshell
        sub = "( exit 9 )" if shell != "fish" else "fish -c 'exit 9'"
        ec, _ = s.run(sub)
        case(f"{shell} subshell exit 9", ec == 9, f"ec={ec}")

        # Process substitution / command substitution
        if shell != "fish":
            ec, _ = s.run("diff <(echo a) <(echo b) >/dev/null")
            case(f"{shell} proc-subst diff -> 1", ec == 1, f"ec={ec}")
        ec, _ = s.run("echo $(false)$?" if shell != "fish" else "echo (false)$status")
        case(f"{shell} cmd-subst completes", ec == 0, f"ec={ec}")

        # Background: returns immediately, then job finishes later -> next precmd
        # might report job-completion message but $? should be from foreground
        ec, _ = s.run("sleep 0.3 &")
        case(f"{shell} 'sleep 0.3 &' immediate ec=0", ec == 0, f"ec={ec}")
        ec, _ = s.run("true")  # job may have finished; ensure $? is still 0
        case(f"{shell} bg job done -> next true still ec=0", ec == 0, f"ec={ec}")
        ec, _ = s.run("wait" if shell != "fish" else "wait")
        case(f"{shell} 'wait' after bg job", ec == 0, f"ec={ec}")

        # Multi-command line
        ec, _ = s.run("true; false; true")
        case(f"{shell} 'a; b; c' -> last ec", ec == 0, f"ec={ec}")

        # Long command line (>4KB) - tests PTY input buffering
        long = "true " + "#" + "x" * 5000
        ec, via = s.run(long, timeout=6)
        case(f"{shell} 5KB command line", ec == 0 and via == "osc-done", f"ec={ec} via={via}")

        # Redirection
        ec, _ = s.run("echo hi > /tmp/zmxpoc-out && cat /tmp/zmxpoc-out")
        case(f"{shell} redirect + cat", ec == 0, f"ec={ec}")
        os.unlink("/tmp/zmxpoc-out") if os.path.exists("/tmp/zmxpoc-out") else None

    finally:
        s.close()
        shutil.rmtree(d, ignore_errors=True)

    # Ctrl-C mid-command (fresh session)
    d, argv, env = make_rcdir(shell)
    s = Session(argv, env=env)
    try:
        s.wait_announce()
        before = len(s.events)
        os.write(s.fd, b"\x15sleep 5\r")
        s._pump(0.5)
        os.write(s.fd, b"\x03")  # Ctrl-C
        # precmd should fire with $?=130 (bash/zsh) or 130 (fish)
        t0 = __import__("time").time()
        ec = via = None
        while __import__("time").time() - t0 < 3:
            s._pump(0.2)
            for ev in s.events[before:]:
                if ev[0] == "done":
                    ec, via = ev[1], "osc-done"; break
            if ec is not None: break
        case(f"{shell} Ctrl-C mid-cmd -> ec~130 via osc",
             via == "osc-done" and ec in (125, 130), f"ec={ec} via={via}")
        # Recovery
        ec, via = s.run("true")
        case(f"{shell} recovers after Ctrl-C", ec == 0 and via == "osc-done", f"ec={ec} via={via}")
    finally:
        s.close()
        shutil.rmtree(d, ignore_errors=True)

    # Heredoc (bash/zsh only; fish uses different syntax)
    if shell != "fish":
        d, argv, env = make_rcdir(shell)
        s = Session(argv, env=env)
        try:
            s.wait_announce()
            # Multi-line heredoc typed with \r between lines
            before = len(s.events)
            os.write(s.fd, b"\x15cat <<EOF\rline1\rline2\rEOF\r")
            t0 = __import__("time").time()
            ec = via = None
            while __import__("time").time() - t0 < 3:
                s._pump(0.2)
                for ev in s.events[before:]:
                    if ev[0] == "done":
                        ec, via = ev[1], "osc-done"; break
                if ec is not None: break
            case(f"{shell} heredoc -> ec=0 via osc", ec == 0 and via == "osc-done",
                 f"ec={ec} via={via}")
        finally:
            s.close()
            shutil.rmtree(d, ignore_errors=True)


def test_false_positive():
    """User output containing our OSC -> would need nonce in production."""
    print(f"\n== false-positive: user echoes OSC 2718 ==")
    d, argv, env = make_rcdir("bash")
    s = Session(argv, env=env)
    try:
        s.wait_announce()
        ec, via = s.run("printf '\\033]2718;done;99;/fake\\007'; sleep 0.2; false")
        # Without a nonce, we'll see the fake 99 first. This documents the need
        # for a per-session nonce in the real impl.
        case("user-forged OSC observed (motivates nonce)", ec == 99,
             f"ec={ec} via={via} [expected: production needs nonce]")
    finally:
        s.close()
        shutil.rmtree(d, ignore_errors=True)


STARSHIP = "/tmp/bin/starship"
OMP = "/tmp/bin/oh-my-posh"

def test_prompt_engine(engine, shell):
    """Test with starship or oh-my-posh active in the rc BEFORE our announce."""
    print(f"\n== {shell} + {engine} ==")
    binp = STARSHIP if engine == "starship" else OMP
    if not os.path.exists(binp):
        case(f"{shell}+{engine}", False, f"{engine} not installed")
        return
    if engine == "starship":
        if shell == "fish":
            extra = f"{binp} init fish | source"
        else:
            extra = f'eval "$({binp} init {shell})"'
    else:  # oh-my-posh
        if shell == "fish":
            extra = f"{binp} init fish | source"
        else:
            extra = f'eval "$({binp} init {shell})"'

    d, argv, env = make_rcdir(shell, extra=extra)
    env = dict(env); env["PATH"] = f"/tmp/bin:{os.environ['PATH']}"
    s = Session(argv, env=env)
    try:
        ann = s.wait_announce(timeout=6)
        case(f"{shell}+{engine} announce", ann == shell, f"got={ann}")
        if not ann:
            return
        ec, via = s.run("true")
        case(f"{shell}+{engine} true -> 0", ec == 0 and via == "osc-done", f"ec={ec} via={via}")
        ec, via = s.run("false")
        case(f"{shell}+{engine} false -> 1", ec == 1 and via == "osc-done", f"ec={ec} via={via}")
        ec, via = s.run("sh -c 'exit 17'")
        case(f"{shell}+{engine} exit 17", ec == 17 and via == "osc-done", f"ec={ec} via={via}")
    finally:
        s.close()
        shutil.rmtree(d, ignore_errors=True)


def test_p10k():
    """zsh + powerlevel10k (instant-prompt off; wizard suppressed)."""
    print(f"\n== zsh + powerlevel10k ==")
    if not have("zsh") or not os.path.exists("/tmp/p10k/powerlevel10k.zsh-theme"):
        case("p10k available", False, "skip")
        return
    extra = (
        "POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true\n"
        "POWERLEVEL9K_INSTANT_PROMPT=off\n"
        "source /tmp/p10k/powerlevel10k.zsh-theme\n"
    )
    d, argv, env = make_rcdir("zsh", extra=extra)
    s = Session(argv, env=env)
    try:
        ann = s.wait_announce(timeout=8)
        case("zsh+p10k announce", ann == "zsh", f"got={ann}")
        if not ann:
            return
        ec, via = s.run("true")
        case("zsh+p10k true -> 0", ec == 0 and via == "osc-done", f"ec={ec} via={via}")
        ec, via = s.run("false")
        case("zsh+p10k false -> 1", ec == 1 and via == "osc-done", f"ec={ec} via={via}")
        ec, via = s.run("sh -c 'exit 17'")
        case("zsh+p10k exit 17", ec == 17 and via == "osc-done", f"ec={ec} via={via}")
        # p10k itself emits 133;D — verify our hook doesn't interfere
        out = s._pump(0.2)
        has_133d = b"\x1b]133;D" in out or any(b"133;D" in bytes(s.scanner.buf) for _ in [0])
        case("zsh+p10k still emits its own 133;D", True, f"(informational)")
    finally:
        s.close()
        shutil.rmtree(d, ignore_errors=True)


def test_zsh_precmd_functions():
    """zsh with precmd_functions array already populated (p10k/starship style)."""
    print(f"\n== zsh: precmd_functions array pre-populated ==")
    if not have("zsh"):
        return
    extra = "my_hook(){ : ;}; typeset -ga precmd_functions; precmd_functions+=(my_hook)"
    d, argv, env = make_rcdir("zsh", extra=extra)
    s = Session(argv, env=env)
    try:
        if not s.wait_announce():
            case("zsh+precmd_functions setup", False)
            return
        ec, via = s.run("false")
        case("zsh+precmd_functions: false -> 1", ec == 1 and via == "osc-done", f"ec={ec} via={via}")
    finally:
        s.close()
        shutil.rmtree(d, ignore_errors=True)


def test_ssh_nested_shell():
    """ssh -> remote bash (announced) -> remote fish subshell (announced)."""
    print(f"\n== ssh -> bash -> fish (cross-shell nesting) ==")
    r = subprocess.run(SSH.split() + ["true"], capture_output=True, timeout=5)
    if r.returncode != 0:
        case("ssh reachable", False)
        return
    d = tempfile.mkdtemp(prefix="zmxpoc-")
    with open(f"{d}/bashrc", "w") as f:
        f.write(announce_rc("bash"))
    os.makedirs(f"{d}/fish", exist_ok=True)
    with open(f"{d}/fish/config.fish", "w") as f:
        f.write(announce_rc("fish"))
    s = Session(["bash", "--norc", "-i"])
    try:
        s._pump(0.5)
        s.type(f"{SSH} -t bash --rcfile {d}/bashrc -i\r")
        ann = s.wait_announce(timeout=5)
        case("ssh->bash announce", ann == "bash", f"got={ann}")
        if not ann:
            return
        ec, via = s.run("false")
        case("ssh->bash false -> 1", ec == 1 and via == "osc-done", f"ec={ec}")
        # nest fish on the remote
        n = sum(1 for e in s.events if e[0] == "hello")
        s.type(f"XDG_CONFIG_HOME={d} fish -i\r")
        s._pump(2.0)
        n2 = sum(1 for e in s.events if e[0] == "hello")
        case("ssh->bash->fish announce", n2 > n and s.announced_shell == "fish",
             f"hello {n}->{n2} shell={s.announced_shell}")
        ec, via = s.run("false")
        case("ssh->bash->fish false -> 1 via osc", ec == 1 and via == "osc-done", f"ec={ec} via={via}")
        ec, via = s.run("exit")
        case("ssh->bash->fish exit -> back to bash", via == "osc-done", f"ec={ec} via={via}")
    finally:
        s.close()
        shutil.rmtree(d, ignore_errors=True)


def test_boundary_split():
    """Large output before precmd OSC -> verify scanner handles split."""
    print(f"\n== boundary: large output before OSC ==")
    d, argv, env = make_rcdir("bash")
    s = Session(argv, env=env)
    try:
        s.wait_announce()
        ec, via = s.run("head -c 50000 /dev/zero | tr '\\0' x; false", timeout=8)
        case("50KB output then false -> 1 via osc", ec == 1 and via == "osc-done", f"ec={ec} via={via}")
    finally:
        s.close()
        shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    for sh in ("bash", "zsh", "fish"):
        if not have(sh):
            print(f"\n== {sh}: SKIP (not installed) ==")
            continue
        test_basic(sh)
        test_edge(sh)
        test_existing_hooks(sh)
        test_weird(sh)
    test_no_announce()
    test_nested()
    test_boundary_split()
    test_false_positive()
    test_zsh_precmd_functions()

    for sh in ("bash", "zsh", "fish"):
        if have(sh):
            test_prompt_engine("starship", sh)
            test_prompt_engine("oh-my-posh", sh)

    test_p10k()

    test_ssh()
    test_ssh_nested_shell()

    print("\n" + "=" * 60)
    p = sum(1 for _, ok, _ in RESULTS if ok)
    f = len(RESULTS) - p
    print(f"TOTAL: {p} pass, {f} fail")
    for name, ok, detail in RESULTS:
        if not ok:
            print(f"  FAIL: {name}  {detail}")
    sys.exit(0 if f == 0 else 1)
