export Slack, RMSPiLine, EMTRLLine, PT1Load, ConstPLoad, PT1PLoadEMT, SecondaryControlCS_PI, SecondaryControlCS_PT1, BSPiLine, ConstLoad

function RMSPiLine(; L, R, C1, C2)
    let ω=2π*50, L=L, R=R, C1=C1, C2=C2
        edgef = function(u, src, dst, p, t)
            Vsrc = Complex(src[1], src[2])
            Vdst = Complex(dst[1], dst[2])
            imain = (Vsrc - Vdst)/(R + im*ω*L)
            iC1 = Vsrc*im*ω*C1
            iC2 = Vdst*im*ω*C2
            isrc = - (imain + iC1) # positiv current means flow to node
            idst = imain - iC2
            u[1] = real(idst)
            u[2] = imag(idst)
            u[3] = real(isrc)
            u[4] = imag(isrc)
        end
        StaticEdge(f=edgef, dim=4, coupling=:fiducial, sym=[:i_r_dst,:i_i_dst, :i_r_src, :i_i_src])
    end
end

function BSPiLine(; p_order=[], params...)
    @variables t i_r_src(t) i_i_src(t) i_r_dst(t) i_i_dst(t)
    @parameters u_r_src(t) u_i_src(t) u_r_dst(t) u_i_dst(t) R X B_src B_dst
    lineblock = IOBlock([i_r_src ~ real(-(u_r_src + im*u_i_src - u_r_dst - im*u_i_dst)/(R + im*X) - (im*B_src)*(u_r_src + im*u_i_src)),
                         i_i_src ~ imag(-(u_r_src + im*u_i_src - u_r_dst - im*u_i_dst)/(R + im*X) - (im*B_src)*(u_r_src + im*u_i_src)),
                         i_r_dst ~ real( (u_r_src + im*u_i_src - u_r_dst - im*u_i_dst)/(R + im*X) - (im*B_dst)*(u_r_dst + im*u_i_dst)),
                         i_i_dst ~ imag( (u_r_src + im*u_i_src - u_r_dst - im*u_i_dst)/(R + im*X) - (im*B_dst)*(u_r_dst + im*u_i_dst))],
                        [u_r_src, u_i_src, u_r_dst, u_i_dst],
                        [i_r_src, i_i_src, i_r_dst, i_i_dst];
                        name=:PiLine)
    lineblock = replace_vars(lineblock, params)
end

function EMTRLLine(; params...)
    @variables t i_r(t) i_i(t)
    @parameters u_r_src(t) u_i_src(t) u_r_dst(t) u_i_dst(t) R L ω0
    dt = Differential(t)
    lineblock = IOBlock([dt(i_r) ~  ω0 * i_i  - R/L * i_r + 1/L*(u_r_src - u_r_dst),
                         dt(i_i) ~ -ω0 * i_r  - R/L * i_i + 1/L*(u_i_src - u_i_dst)],
                        [u_r_src, u_i_src, u_r_dst, u_i_dst],
                        [i_r, i_i],
                        name=:RLLine)
    lineblock = set_p(lineblock, params)
    if !isempty(lineblock.iparams)
        @warn "There are open parameters on this line: $(lineblock.iparams)"
    end
    ODEEdge(lineblock)
end

function Slack()
    @variables t u_r(t) u_i(t)
    dt = Differential(t)
    slackblock = IOBlock([dt(u_r) ~ 0, dt(u_i) ~ 0], [], [u_r, u_i]; name=:slack)
    ODEVertex(slackblock)
end

function ConstPLoad(;params...)
    @variables t P_meas(t) Q_meas(t) u_r(t) u_i(t)
    @parameters P_ref i_r(t) i_i(t)
    loadblock = IOBlock([P_meas ~ -u_r*i_r - u_i*i_i,
                         Q_meas ~ -i_r*u_i + i_i*u_r,
                         0 ~ Q_meas,
                         0 ~ P_ref - P_meas],
                        [i_r, i_i], [u_r, u_i],
                        name=:load)
    loadblock = substitute_algebraic_states(loadblock)
    loadblock = set_p(loadblock, params)

    ODEVertex(loadblock, ModelingToolkit.getname.(loadblock.iparams))
end

function ConstLoad(;EMT=false, params...)
    cs = Components.PerfectCurrentSource(;name=:load_cs, P=:P_load, Q=:Q_load)
    bus = BusBar(cs; name=:pt1load, autopromote=true, EMT)
    bus = replace_vars(bus, params)
end

function PT1Load(;EMT=false, params...)
    cs = Components.PT1CurrentSource(;name=:load_cs, P=:P_load, Q=:Q_load)
    bus = BusBar(cs; name=:pt1load, autopromote=true, EMT)
    bus = replace_vars(bus, params)
end

function SecondaryControlCS_PI(; EMT=false, params...)
    cs = Components.PT1CurrentSource()
    cs = set_p(cs; τ=0.001)

    pll = Components.ReducedPLL()
    pll = set_p(pll; ω_lp=1.32 * 2π*50, Kp=20.0, Ki=2.0)

    @variables t P_ref_pi(t) μ(t)
    @parameters P_ref ω(t) Ki Kp
    dt = Differential(t)
    ctrl = IOBlock([dt(μ) ~ -ω,
                    P_ref_pi ~ P_ref + Ki*μ - Kp*ω],
                   [ω], [P_ref_pi],
                   name=:PrefICtrl)

    @named pisrc = IOSystem([pll.ω_pll=>ctrl.ω,
                             ctrl.P_ref_pi=>cs.P_ref],
                            [pll, cs, ctrl],
                            outputs=[cs.i_r, cs.i_i],
                            globalp=[:u_r, :u_i])
    pisrc = connect_system(pisrc)

    bus = BusBar(pisrc; autopromote=true, EMT)
    bus = set_p(bus, params)
    ODEVertex(bus, ModelingToolkit.getname.(bus.iparams))
end

function SecondaryControlCS_PT1(; EMT=false, params...)
    cs = Components.PT1CurrentSource(;:P_ref=>:P_ref_int, :τ=>:τ_cs)

    lpf = Components.LowPassFilter(;:output=>:P_ref_int, :input=>:P_ref)
    lpf = make_iparam(lpf, :P_ref)

    cs = @connect lpf.P_ref_int => cs.P_ref_int outputs=:remaining name=:cs

    bus = BusBar(cs; autopromote=true, EMT)
    bus = set_p(bus, params)
    ODEVertex(bus, ModelingToolkit.getname.(bus.iparams))
end
