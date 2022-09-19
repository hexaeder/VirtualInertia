using Test
using EMTSim
using BlockSystems
using Plots
using OrdinaryDiffEq
using SteadyStateDiffEq
using NetworkDynamics
using Graphs
using DiffEqCallbacks

## This parameter set was used in a small EMT experiment with
ω0    = 2π*50u"rad/s"
Sbase = 5u"kW"
Vbase = 230u"V"
Ibase = Sbase/(Vbase) |> u"A"
Cbase = Ibase/Vbase
Lbase = Vbase/Ibase
Rbase = (Vbase^2)/Sbase

## values from 10km
Rline = 0.354u"Ω" / Rbase       |> u"pu"
Lline = 350e-6u"H" / Lbase      |> u"s"
Cline = 2*(12e-6)u"F" / Cbase   |> u"s"

@testest "Doop Control test on step load" begin
    load = ConstPLoad()
    @test load.f.params == [:P_ref]
    droopPT1 = ODEVertex(EMTSim.PT1Source(τ=0.001),
                         EMTSim.DroopControl(Q_ref=0,
                                             V_ref=1, ω_ref=0,
                                             τ_P=0.01, K_P=0.1,
                                             τ_Q=0.01, K_Q=0.1))
    @test droopPT1.f.params == [:P_ref]

    rmsedge = RMSPiLine(R=0, L=ustrip(Lline), C1=ustrip(Cline/2), C2=ustrip(Cline/2))

    g = complete_graph(2)
    nd = network_dynamics([load, droopPT1], rmsedge, g)
    uguess = u0guess(nd)
    p = ([-1.0, 1.0], nothing) # node parameters and (empty) line parameters
    ssprob = SteadyStateProblem(nd, uguess, p)
    u0 = solve(ssprob, DynamicSS(Rodas4()))

    #=
    To test the inverer response, we need to add a callback to the system which increases
    the load at a certain point.
    =#
    function affect(integrator)
        integrator.p = ([-1.1, 1.0], nothing)
        auto_dt_reset!(integrator)
    end
    cb = PresetTimeCallback(0.1, affect)

    tspan = (0.0, 1.0)
    prob = ODEProblem(nd, u0, tspan, p; callback=cb)
    sol = solve(prob, Rodas4(), dtmax=0.1)


    EMTSim.set_ts_dtmax(0.0005)
    pmeas1 = plot(timeseries(sol,1,:P_meas); label="P_meas at load")
    pmeas2 = plot(timeseries(sol,2,:P_meas); label="P_meas at conv")
    plot!(pmeas2, timeseries(sol,2,:P_fil); label="P_fil at conv")

    qmeas2 = plot(timeseries(sol,2,:Q_meas); label="Q_meas at conv")
    plot!(qmeas2, timeseries(sol,2,:Q_fil); label="Q_fil at conv")

    ωplot = plot(timeseries(sol,2,:ω); label="ω at conv")
    vabc = plot(timeseries(sol,2,:Va); label="Va at conv")
    plot!(timeseries(sol,2,:Vb); label="Vb")
    plot!(timeseries(sol,2,:Vc); label="Vc")

    Vplot = plot(timeseries(sol,2,:Vmag); label="Vmag at conv")
    plot!(Vplot, timeseries(sol,2,:Vmag_ref); label="Vmag setpoint")

    allp = [vabc, pmeas1, pmeas2, qmeas2, Vplot, ωplot]
    plot(allp..., layout=(6,1), size=(1000,1500))
    xlims!(0.099, 0.16)
end

@testset "SecondaryControl_CS" begin
    rmsedge = RMSPiLine(R=0,
                        L=3.30812854442344e-5,
                        C1=0.00012696,
                        C2=0.00012696)
    second_ctrl = SecondaryControlCS(; EMT=false, Ki=5, Kp=0)
    ####
    #### First on slack
    ####
    slack = Slack()

    g = complete_graph(2)
    nd = network_dynamics([second_ctrl, slack], rmsedge, g)
    uguess = u0guess(nd)
    p = ([-1.0, 1.0], nothing) # node parameters and (empty) line parameters
    tspan = (0.0, 10.0)
    prob = ODEProblem(nd, uguess, tspan, p)
    sol = solve(prob, Rodas4())
    plot(sol)

    ####
    #### Then on droop controller
    ####
    droopPT1 = ODEVertex(EMTSim.PT1Source(τ=0.001),
                         EMTSim.DroopControl(Q_ref=0,
                                             V_ref=1, ω_ref=0,
                                             τ_P=0.01, K_P=0.1,
                                             τ_Q=0.01, K_Q=0.1))

    g = complete_graph(2)
    nd = network_dynamics([second_ctrl, droopPT1], rmsedge, g)

    uguess = u0guess(nd)

    p = ([-1.0, 1.0], nothing) # node parameters and (empty) line parameters
    tspan = (0.0, 30.0)
    prob = ODEProblem(nd, uguess, tspan, p)
    sol = solve(prob, Rodas4())
    plot(sol)

    plot(timeseries(sol, 1, :Vmag), label="Vmag @ secondary control")
    plot!(timeseries(sol, 2, :Vmag), label="Vmag @ droop")

    plot(timeseries(sol, 1, :Varg), label="Varg @ secondary control")
    plot!(timeseries(sol, 2, :Varg), label="Varg @ droop")

    u0 = sol[end]

    ####
    #### Change injected power and watch pi action
    ####
    function affect(integrator)
        integrator.p = ([-1.0, 1.1], nothing)
        auto_dt_reset!(integrator)
    end
    tspan = (0, 10)
    cb = PresetTimeCallback(1.0, affect)
    prob = ODEProblem(nd, u0, tspan, p; callback=cb)
    sol = solve(prob, Rodas4())

    plot(timeseries(sol, 1, :Vmag), label="Vmag @ secondary control")
    plot!(timeseries(sol, 2, :Vmag), label="Vmag @ droop")

    plot(timeseries(sol, 1, :Varg), label="Varg @ secondary control")
    plot!(timeseries(sol, 2, :Varg), label="Varg @ droop")

    plot(timeseries(sol, 1, :Pmeas), label="Pmeas @ secondary control")
    plot!(timeseries(sol, 2, :Pmeas), label="Pmeas @ secondary control")

    plot(timeseries(sol, 1, :ω_pll), label="ω_pll @ secondary control")
    plot(twinx(),timeseries(sol, 1, :P_ref_pi), label="Pref @ secondary control")
end

@testest "PT1 Load" begin
    rmsload = PT1PLoad()
    rmsload.f.params

    emtload = PT1PLoad(EMT=true)
    emtload.f.params

    old = EMTSim.PT1PLoadEMT()
    old.f.params
end

@testset "EMT: Droop on EMT PT1 load" begin
    load = PT1PLoad(EMT=true, ω0=ustrip(u"rad/s", ω0),
                    C=ustrip(u"s", Cline)/2,
                    τ=1/(2π*50))

    droopPT1 = ODEVertex(EMTSim.PT1Source(;τ=0.001),
                         EMTSim.DroopControl(Q_ref=0,
                                             V_ref=1, ω_ref=0,
                                             τ_P=0.01, K_P=0.1,
                                             τ_Q=0.01, K_Q=0.1))

    edge = EMTRLLine(R=0,#ustrip(u"pu", Rline),
                     L=ustrip(u"s",Lline),
                     ω0=ustrip(u"rad/s", ω0))

    g = complete_graph(2)
    nd = network_dynamics([load, droopPT1], edge, g)
    uguess = u0guess(nd)
    p = ([-1.0, 1.0], nothing) # node parameters and (empty) line parameters
    tspan = (0.0, 5)
    prob = ODEProblem(nd, uguess, tspan, p)
    sol = solve(prob, Rodas4())
    plot(sol)
    u0 = sol[end]

    function affect(integrator)
        integrator.p = ([-0.9, 1.0], nothing)
        auto_dt_reset!(integrator)
    end
    cb = PresetTimeCallback(0.1, affect)

    tspan = (0.0, 2.0)
    prob = ODEProblem(nd, u0, tspan, p; callback=cb)
    sol = solve(prob, Rodas4())

    vmag = plot(timeseries(sol,1,:Vmag); label="Vmag at load")
    plot!(timeseries(sol,2,:Vmag); label="Vmag at Conv")

    varg = plot(timeseries(sol,1,:Varg); label="Varg at load")
    plot!(timeseries(sol,2,:Varg); label="Varg at Conv")

    pmeas1 = plot(timeseries(sol,1,:Pmeas); label="P_meas at load")
    pmeas2 = plot(timeseries(sol,2,:Pmeas); label="P_meas at conv")
    plot!(pmeas2, timeseries(sol,2,:P_fil); label="P_fil at conv")

    qmeas2 = plot(timeseries(sol,2,:Q_meas); label="Q_meas at conv")
    plot!(qmeas2, timeseries(sol,2,:Q_fil); label="Q_fil at conv")

    ωplot = plot(timeseries(sol,2,:ω); label="ω at conv")

    set_ts_dtmax(0.00001)
    # vabc = plot(timeseries(sol,1,:Va); label="Va at conv")
    # plot!(timeseries(sol,1,:Vb); label="Vb")
    # plot!(timeseries(sol,1,:Vc); label="Vc")
    vabc = plot(timeseries(sol,2,:ia); label="ia at conv")
    plot!(timeseries(sol,2,:ib); label="ib")
    plot!(timeseries(sol,2,:ic); label="ic")
    xlims!(0.09,0.14)
    # ylims!(0.7, 0.9)


    Vplot = plot(timeseries(sol,2,:Vmag); label="Vmag at conv")
    plot!(Vplot, timeseries(sol,2,:Vmag_ref); label="Vmag setpoint")

    allp = [vabc, pmeas1, pmeas2, qmeas2, Vplot, ωplot]
    plot(allp..., layout=(6,1), size=(1000,1500))
    xlims!(0.09, 0.13)
end
