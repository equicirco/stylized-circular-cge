"""
Model-local calibration-set helpers built on JCGECalibrate containers.
"""

struct CalibrationSet
    name::Symbol
    parameters::JCGECalibrate.LabeledVector{Float64}
    single_sam::JCGECalibrate.SAMTable
    two_country_sam::JCGECalibrate.SAMTable
end

"""
    datadir()

Return the package data directory.
"""
datadir() = normpath(joinpath(@__DIR__, "..", "..", "data"))

function _strings(items)
    return [string(item) for item in items]
end

function _load_single_sam(path::AbstractString)
    return JCGECalibrate.load_sam_table(path;
        goods = _strings(GOODS),
        factors = _strings(FACTORS),
        numeraire_factor_label = "LAB",
        indirectTax_label = "IDT",
        tariff_label = "TRF",
        households_label = "HOH",
        government_label = "GOV",
        investment_label = "IDT",
        restOfTheWorld_label = "GOV",
        label_col = "account")
end

function _load_two_country_sam(path::AbstractString)
    return JCGECalibrate.load_sam_table(path;
        goods = _strings(TWO_COUNTRY_PRODUCTION_ACTIVITIES),
        factors = _strings(TWO_COUNTRY_FACTORS),
        numeraire_factor_label = "LAB_C",
        indirectTax_label = "NFA",
        tariff_label = "NFA",
        households_label = "HOH_C",
        government_label = "HOH_C",
        investment_label = "NFA",
        restOfTheWorld_label = "NFA",
        label_col = "account")
end

"""
    load_calibration_set(name=:round_number; data_dir=datadir())

Load the stylized model calibration set. SAM matrices are loaded with
`JCGECalibrate.load_sam_table`; scalar behavioural and physical parameters are
loaded with `JCGECalibrate.load_labeled_vector`.
"""
function load_calibration_set(name::Symbol = :round_number; data_dir::AbstractString = datadir())
    name === :round_number || error("Unknown calibration set $(name)")
    parameters = JCGECalibrate.load_labeled_vector(
        joinpath(data_dir, "round_number_parameters.csv");
        label_col = "label",
        value_col = "value")
    single_sam = _load_single_sam(joinpath(data_dir, "synthetic_sam.csv"))
    two_country = _load_two_country_sam(joinpath(data_dir, "two_country_synthetic_sam.csv"))
    return CalibrationSet(name, parameters, single_sam, two_country)
end

"""
    default_calibration_set()

Load the default round-number calibration set used by the stylized model.
"""
default_calibration_set() = load_calibration_set(:round_number)

calibration_value(calibration::CalibrationSet, label::Symbol) = calibration.parameters[label]

function calibration_parameters(calibration::CalibrationSet = default_calibration_set())
    return (
        delta = calibration_value(calibration, :delta),
        metal_quality = calibration_value(calibration, :metal_quality),
        sigma_metal = calibration_value(calibration, :sigma_metal),
        sigma_routes = calibration_value(calibration, :sigma_routes),
        sigma_eol = calibration_value(calibration, :sigma_eol),
        eta_service = calibration_value(calibration, :eta_service),
        yield = (
            ref = calibration_value(calibration, :yield_ref),
            rep = calibration_value(calibration, :yield_rep),
            reu = calibration_value(calibration, :yield_reu),
            rmtl = calibration_value(calibration, :yield_rmtl),
        ),
        metal_intensity = (
            new = calibration_value(calibration, :metal_intensity_new),
            ref = calibration_value(calibration, :metal_intensity_ref),
            rep = calibration_value(calibration, :metal_intensity_rep),
            reu = calibration_value(calibration, :metal_intensity_reu),
        ),
    )
end

calibration_stock0(calibration::CalibrationSet = default_calibration_set()) =
    calibration_value(calibration, :stock0)

function _sam_values(table::JCGECalibrate.SAMTable, accounts)
    matrix = table.sam
    values = Dict{Tuple{Symbol,Symbol},Float64}()
    for row in accounts, col in accounts
        haskey(matrix.row_index, row) || error("Calibration SAM is missing row $(row)")
        haskey(matrix.col_index, col) || error("Calibration SAM is missing column $(col)")
        values[(row, col)] = matrix[row, col]
    end
    return values
end
