using System;
using System.Linq;
using System.Threading;

public static class AgentPlaytestFixture {
    static string Mode => Environment.GetEnvironmentVariable("DB_AGENT_FIXTURE_MODE") ?? "valid";
    static void State(int schema, long tick, string battery = "100") => Console.WriteLine(
        $"AGENT_STATE schema={schema} tick={tick} frame=0 room=12 pos=0,0.08,15.5 velocity=0,0,0 yaw=0 pitch=0 battery={battery} souls=0 active_enemies=1 exposed_souls={(Mode == "nan-soul" ? 1 : 0)} goals=0/1 clear=0 dead=0 frame_capture=1 scenario=interactive build_commit={new string('a',40)} build_configuration=Release frame_file=\"observation.ppm\"");
    static void Observation(int schema = 4, long tick = 0) {
        State(schema, tick, Mode == "nan-state" ? "NaN" : "100");
        Console.WriteLine(Mode == "malformed-objective" ? $"AGENT_OBJECTIVE schema={schema} tick={tick} valid=1 id=0" : $"AGENT_OBJECTIVE schema={schema} tick={tick} valid=1 id=0 pos_m=0,3,-19 distance_m=35");
        if (Mode != "missing-soul") Console.WriteLine(Mode == "nan-soul" ? $"AGENT_SOUL schema={schema} tick={tick} valid=1 id=0 pos_m=0,0,-5 distance_m=NaN" : $"AGENT_SOUL schema={schema} tick={(Mode == "tick-mismatch" ? tick + 1 : tick)} valid=0 id=-1");
        if (Mode == "protocol-error") Console.WriteLine("AGENT_PLAYTEST_ERROR reason=fixture_failure");
        Console.WriteLine($"AGENT_ENEMY schema={schema} tick={tick} valid=1 id=0 distance_m=10 armor=2 pos_m=0,0.08,-5");
        Console.Out.Flush();
    }
    public static int Main(string[] args) {
        if (args.Contains("--build-identity-json")) { if (Mode == "identity-silent") Thread.Sleep(5000); Console.WriteLine($"{{\"commit\":\"{new string('a',40)}\"}}"); return 0; }
        if (Mode == "silent") { Thread.Sleep(5000); return 0; }
        if (Mode == "stderr") { Console.Error.Write(new string('x', 200000)); Console.Error.Flush(); }
        Observation(Mode == "schema3" ? 3 : 4);
        while (Console.ReadLine() is string command) {
            if (command == "quit") return 0;
            Observation(Mode == "schema3" ? 3 : 4, 1);
        }
        return 0;
    }
}
